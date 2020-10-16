pragma solidity 0.4.26;

import "./ECRC20/EFGToken.sol";
import "./ECRC20/GPTToken.sol";

contract ECRC20 {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);
    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

contract LendingContract {
    address owner;
    address[] pool;
    EFGToken EFG;
    GPTToken GPT;
    ECRC20[] asset; /* Token type to inherit transfer() and balanceOf() */
    bytes8[] assetName; /* all ECRC20 token symbols that can be accepted as collateral */
    address[] assetAddress; /* all ECRC20 contract addresses that can be accepted as collateral */
    uint256 secsInYear = 365 * 24 * 60 * 60;

    mapping(address => bool) private oracles;
    mapping(bytes8 => uint256) private collateralRates; /* 4 decimal places */
    mapping(bytes8 => uint256) private EFGRates; /* 6 decimal places */
    mapping(bytes8 => uint256) private interestRates; /* 4 decimal places */
    mapping(address => mapping(bytes8 => uint256)) private balance; /* 8 decimal places for ECOC and all ECRC20 tokens */
    mapping(address => uint256) private EFGBalance; /* 8 decimal places */

    struct Pool {
        bytes32 name;
        mapping(address => mapping(bytes8 => uint256)) collateral; /* 8 decimal places */
        uint256 remainingEFG; /* 8 decimal places */
    }
    mapping(address => Pool) private poolsData;

    struct Loan {
        bytes8 assetSymbol; /* can be ECOC or any ECRC20 */
        uint256 amount; /* in EFG , 8 digits */
        uint256 timestamp; /* timestamp of last update (creation or partial repay) */
        uint256 interestRate; /* Initial interast rate (depends on asset), 6 digits */
        uint256 xrate; /* Initial exchange rate EFG/assetSymbol , 6 digits */
        uint256 interest; /* accumilated interest , 8 digits */
        address pool; /* pool address */
    }
    mapping(address => Loan) private debt;

    /* Events */
    event LockECOCEvent(address depositor, uint256 ecoc_amount);
    event LockAssetEvent(bool result, bytes8 _symbol, address depositor, uint256 _amount);
    event WithdrawECOCEvent(
        address user_account,
        address beneficiar,
        uint256 ecoc_amount
    );
    event WithdrawEFGEvent(address beneficiar, uint256 efg_amount);
    event WithdrawAssetEvent(bool result, address beneficiar, bytes8 symbol, uint256 _amount);
    event BorrowEvent(
        bool newLoan,
        address pool,
        address borrower,
        uint256 EFG_amount
    );
    event MarginCallEvent(
        address pool,
        address borrower,
        bytes32 assetSymbol,
        uint256 asset_amount
    );
    event RepayEvent(bool fullyRepaid, address debtors_addr, uint256 amount);

    constructor(address _EFG_addr, address _GPT_addr) public {
        owner = msg.sender;
        EFG = EFGToken(_EFG_addr); /* smart contract address of EFG */
        GPT = GPTToken(_GPT_addr); /* smart contract address of GPT */

        /* interestRate is the rate per year the borrow must pay back
         * Initial rate is 10% per year
         * 4 decimal places (1,000/10,000=0.1=10%)
         */
        interestRates["ECOC"] = 1000;

        /* Initial collateral rate of ECOC is 25% , 4 decimal places. */
        collateralRates["ECOC"] = 2500;
    }

    modifier ownerOnly() {
        require(msg.sender == owner);
        _;
    }

    modifier poolOwnerOnly() {
        bool exists;
        for (uint256 i = 0; i < pool.length; i++) {
            if (pool[i] == msg.sender) {
                exists = true;
                break;
            }
        }
        require(exists);
        _;
    }

    modifier poolExists(address _pool_addr) {
        bool exists;
        /* also allow zero address */
        if (_pool_addr == address(0x0)) {
            _;
        }
        for (uint256 i = 0; i < pool.length; i++) {
            if (pool[i] == _pool_addr) {
                exists = true;
                break;
            }
        }
        require(exists);
        _;
    }
    
    modifier oracleOnly() {
        require(oracles[msg.sender]);
        _;
    }

    modifier canSeize(address _debtors_addr) {
        /* check if a loan exists */
        Loan storage l =  debt[_debtors_addr];
        require(l.amount != 0);
        /* check if the caller is the pool leader*/
        address poolAddress = l.pool;
        require(msg.sender == poolAddress) ;
        /* get total debt*/
        uint256 totalDebt;
        (totalDebt,) = getDebt(_debtors_addr);
        /* compute current collateral value for this asset*/
        Pool storage p = poolsData[poolAddress];
        uint256 collateralValue = (p.collateral[_debtors_addr][l.assetSymbol] *
            EFGRates[l.assetSymbol]) / 1e6; /* rate has 6 decimal places */

        require(totalDebt > collateralValue);
        _;
    }

    /*
     * @notice add new asset, only contract owner
     * @param _symbol - the symbol of the asset
     * @param  _contract_addr - smart contract address of the ECRC20
     * @return an uint256 , the current number of ECRC20
     */
    function addNewAsset(bytes8 _symbol, address _contract_addr)
        external
        ownerOnly()
        returns (uint256)
    {
        assetAddress.push(_contract_addr);
        assetName.push(_symbol);
        ECRC20 newToken = ECRC20(_contract_addr);
        asset.push(newToken);
        return assetAddress.length;
    }

    /*
     * @notice add new pool, only contract owner
     * @param _name - the pool name
     * @param  _leader_addr - address of the depositor(pool leader)
     * @param  _EFG_amount - initial EFG amount for the pool
     * @return an uint256 , the current number of pools
     */
    function addNewPool(
        bytes8 _name,
        address _leader_addr,
        uint256 _EFG_amount
    ) external ownerOnly() returns (uint256) {
        pool.push(_leader_addr);
        Pool storage p = poolsData[_leader_addr];
        p.name = _name;
        p.remainingEFG = _EFG_amount;
        return pool.length;
    }

    /*
     * @notice add or purge oracles, only contract owner
     * @param _oracleAddr - the address of the oracle to be add or remove
     * @param _action - a boolean , if true add to list; else unauthorize
     * @return a boolean , true on success
     */
    function authOracles(address _oracleAddr, bool _action)
        public
        ownerOnly()
        returns (bool)
    {
        oracles[_oracleAddr] = _action;
        return true;
    }

    /*
     * @notice get exchange rate , 6 decimal places
     * @param _symbol
     * @return uint - the exchange rate between EFG and the asset
     */
    function getEFGRates(bytes8 _symbol) public view returns (uint256) {
        return EFGRates[_symbol];
    }

    /*
     * @notice set exchnage rate , 6 decimal places, only authorized oracle
     * @param _symbol
     * @param _rate
     * @return bool
     */
    function setEFGRate(bytes8 _symbol, uint256 _rate)
        external
        oracleOnly()
        returns (bool)
    {
        EFGRates[_symbol] = _rate;
        return true;
    }

    /*
     * @notice set interest rate , 4 decimal places, only contract owner
     * @param _symbol
     * @param _interestRate
     * @return bool
     */
    function setInterestRate(bytes8 _symbol, uint256 _interestRate)
        external
        ownerOnly()
        returns (bool)
    {
        interestRates[_symbol] = _interestRate;
        return true;
    }

    /*
     * @notice get interest rate, 4 decimal places
     * @param _symbol
     * @return uint - the interest rate of the asset
     */
    function getInterestRate(bytes8 _symbol) public view returns (uint256) {
        return interestRates[_symbol];
    }

    /*
     * @notice set collateral rate , 4 decimal places, only contract owner
     * @param _symbol
     * @param _rate
     * @return bool
     */
    function setCollateralRate(bytes8 _symbol, uint256 _rate)
        public
        ownerOnly()
        returns (bool)
    {
        /* rate shoude be in range (0-100%) */
        require(_rate > 0);
        require(_rate < 10000);
        collateralRates[_symbol] = _rate;
        return true;
    }

    /*
     * @notice get collateral rate, 4 decimal places
     * @param _symbol
     * @return bool
     */
    function getCollateralRate(bytes8 _symbol) public view returns (uint256) {
        return collateralRates[_symbol];
    }

    /* Not payable, don't accept ECOC deposits directly - throw the transaction */
    function() external {}

    /*
     * @notice Deposit ECOC
     * @param _pool_addr
     * @return bool
     */
    function lockECOC(address _pool_addr)
        external
        payable
        poolExists(_pool_addr)
        returns (bool)
    {
        require(msg.value > 0);
        /* check if there is no Loan for ECOC */
        Loan memory l = debt[msg.sender];
        require(l.assetSymbol != "ECOC");

        Pool storage p = poolsData[_pool_addr];
        p.collateral[msg.sender]["ECOC"] += msg.value;

        emit LockECOCEvent(msg.sender, msg.value);
        return true;
    }
    
    /*
     * @notice Deposit ECRC20
     * @param _symbol - asset symbol
     * @param _mount - amount of ECRC tokens
     * @param _pool_addr
     * @return bool
     */
    function lockAsset(bytes8 _symbol, uint256 _amount, address _pool_addr)
        external
        poolExists(_pool_addr)
        returns (bool)
    {
        require(_amount > 0);
        for (uint i=0; i<assetName.length; i++) {
            if (assetName[i] == _symbol) {
                ECRC20 token = ECRC20(assetAddress[1]);
                break;
            }
            return false;
        }
        /* check if there is no Loan for this asset */
        Loan memory l = debt[msg.sender];
        require(l.assetSymbol != _symbol);
        
        /* send the tokens , it will fail if not appoved before */
        bool result = token.transferFrom(msg.sender, address(this), _amount);
        if (!result) {
            emit LockAssetEvent(false, _symbol, msg.sender, _amount);
            return false;
        }
        

        Pool storage p = poolsData[_pool_addr];
        p.collateral[msg.sender][_symbol] += _amount;
        emit LockAssetEvent(true, _symbol, msg.sender, _amount);
        return true;
    }

    /*
     * @notice use _symbol asset as collateral
     * @param _symbol symbolAsset
     * @param _pool_addr address of the pool
     * @param _amount of asset as collateral
     * @return uint256 - total borrowed EFG
     */
    function borrow(
        bytes8 _symbol,
        address _pool_addr,
        uint256 _amount
    ) public poolExists(_pool_addr) returns (uint256) {
        require(enoughCollateral(_symbol, _amount, _pool_addr));
        Pool storage p = poolsData[_pool_addr];
        Loan storage l = debt[msg.sender];
        bool loanIsNew = (l.timestamp == 0);
        require(loanIsNew || l.assetSymbol == _symbol);

        uint256 EFGAmount = (_amount *
            collateralRates[_symbol] *
            EFGRates[_symbol]) / 1e10;
        require(EFGAmount <= p.remainingEFG);

        /* save loan info */
        if (loanIsNew) {
            l.assetSymbol = _symbol;
            l.xrate = EFGRates[_symbol];
            l.interestRate = getInterestRate(_symbol);
            l.interest = 0;
            l.pool = _pool_addr;
        } else {
            l.interest +=
                (l.amount *
                    ((block.timestamp - l.timestamp) * l.interestRate)) /
                (secsInYear * 1e4);
        }
        l.timestamp = block.timestamp;
        l.amount += EFGAmount;
        p.remainingEFG -= EFGAmount;

        emit BorrowEvent(loanIsNew, _pool_addr, msg.sender, EFGAmount);
        return EFGAmount;
    }

    /*
     * @notice used by borrow() function to avoid stack too deep problem
     * @param _symbol - asset symbol
     * @param _amount - amount of asset
     * @param _pool_addr - pool where the loan belongs
     * @param uint - the total debt in EFG
     * @return bool - return true if everything is ok, else false
     */
    function enoughCollateral(
        bytes8 _symbol,
        uint256 _amount,
        address _pool_addr
    ) internal view returns (bool) {
        if (_amount <= 0) {
            return false;
        }
        /* asset should exist */
        if (EFGRates[_symbol] == 0) {
            return false;
        }

        Pool storage p = poolsData[_pool_addr];
        if (_amount > p.collateral[msg.sender][_symbol]) {
            return false;
        }

        (uint256 currentDebt, ) = getDebt(msg.sender);
        uint256 borrowPower = ((p.collateral[msg.sender][_symbol] - _amount) *
            collateralRates[_symbol]) / 1e4;
        return ((borrowPower * EFGRates[_symbol]) / 1e6 > currentDebt);
    }

    /*
     * @notice get EFG amount of debt
     * @param _debtor
     * @return uint - the total debt in EFG
     * @return address - the pool where the loan exists
     */
    function getDebt(address _debtor) public view returns (uint256, address) {
        Loan memory d = debt[_debtor];
        uint256 totalDebt = d.amount + d.interest;
        uint256 lastInterest = ((d.amount *
            ((block.timestamp - d.timestamp) * d.interestRate)) /
            (secsInYear * 1e4));
        totalDebt += lastInterest;
        return (totalDebt, d.pool);
    }

    /*
     * @notice fully or partially repay ECOC
     * @param _amount of EFG to be payed back
     * @return bool
     */
    function repay(uint256 _amount) external returns (bool) {
        require(_amount > 0);
        require(_amount <= EFGBalance[msg.sender]);

        Loan storage d = debt[msg.sender];
        require(d.amount !=0 );
        Pool storage p = poolsData[d.pool];

        if (_amount <= d.interest) {
            /* repay the interest first */
            d.interest -= _amount;
            EFGBalance[msg.sender] -= _amount;
            p.remainingEFG += _amount;
            emit RepayEvent(false , msg.sender, _amount);
            return true;
        }

        /* repay amount is greater than interest, decrease the loan */
        uint256 amountLeft = _amount - d.interest;
        d.interest = 0;
        if (d.amount > amountLeft) {
            d.amount -= amountLeft;
            EFGBalance[msg.sender] -= _amount;
            p.remainingEFG += _amount;
            emit RepayEvent(false , msg.sender, _amount);
            return true;
        } else {
            /* loan repayed in full, release the collateral */
            amountLeft -= d.amount;
            d.amount = 0;
            EFGBalance[msg.sender] -= (_amount - amountLeft);
            p.remainingEFG += (_amount - amountLeft);
            balance[msg.sender][d.assetSymbol] += p.collateral[msg.sender][d.assetSymbol];
            p.collateral[msg.sender][d.assetSymbol] = 0;
            emit RepayEvent(true , msg.sender, _amount - amountLeft);
            return true;
        }
    }

    /*
     * @notice withdraw ECOC
     * @param _amount of ECOC to be withdrawn
     * @param _beneficiars_addr
     * @return bool
     */
    function withdrawECOC(uint256 _amount, address _beneficiars_addr)
        external
        payable
        returns (bool)
    {
        require(_amount > 0);
        require(_amount <= balance[msg.sender]["ECOC"]);
        balance[msg.sender]["ECOC"] -= _amount;
        _beneficiars_addr.transfer(_amount);

        emit WithdrawECOCEvent(msg.sender, _beneficiars_addr, _amount);
        return true;
    }

    /*
     * @notice withdraw EFG
     * @param _amount of EFG
     * @return bool
     */
    function withdrawEFG(uint256 _amount) external returns (bool) {
        require(_amount > 0);
        require(EFGBalance[msg.sender] >= _amount);
        EFGBalance[msg.sender] -= _amount;
        /* send the tokens */
        EFG.transfer(msg.sender, _amount);
        emit WithdrawEFGEvent(msg.sender, _amount);
        return true;
    }
    
    /*
     * @notice withdraw Asset (ECRC20)
     * @param _amount of asset to be withdrawn
     * @return bool
     */
    function withdrawAsset(bytes8 _symbol, uint256 _amount) external returns (bool) {
        require(_amount > 0);
        for (uint i=0; i<assetName.length; i++) {
            if (assetName[i] == _symbol) {
            require(balance[msg.sender][_symbol] >= _amount);
            balance[msg.sender][_symbol] -= _amount;
            /* send the tokens */
            asset[i].transfer(msg.sender, _amount);
            emit WithdrawAssetEvent(true, msg.sender, _symbol, _amount);
            return true;
            }
        }
        emit WithdrawAssetEvent(false, msg.sender, _symbol, _amount);
        return false; 
    }

    /*
     * @notice margin call, only by pool owner and only on the condition that collateral has fallen short
     * @param _debtors_addr
     * @return bool
     */
    function marginCall(address _debtors_addr)
        external
        ownerOnly()
        canSeize(_debtors_addr)
        returns (bool)
    {
        /* seize the collateral */
        Loan storage l = debt[_debtors_addr];
        Pool storage p = poolsData[l.pool];
        balance[l.pool][l.assetSymbol] +=  p.collateral[_debtors_addr][l.assetSymbol];

         emit  MarginCallEvent(l.pool, _debtors_addr, l.assetSymbol,
            p.collateral[_debtors_addr][l.assetSymbol]);

        p.collateral[_debtors_addr][l.assetSymbol] = 0;
        /* reset the loan data */
        l.assetSymbol = "";
        l.amount = 0;
        l.timestamp = 0;
        l.interestRate = 0;
        l.xrate = 0;
        l.interest = 0;
        l.pool = address(0);

        return true;
    }

    /*
     * @notice display EFG balance
     * @param _address beneficiar's address
     * @return uint256
     */
    function getEFGBalance(address _address) external view returns (uint256) {
        return EFGBalance[_address];
    }

    /*
     * @notice display asset balance
      @param _symbol asset
     * @param _address beneficiar's address
     * @return uint256
     */
    function getAssetBalance(bytes8 _symbol, address _address)
        external
        view
        returns (uint256)
    {
        return balance[_address][_symbol];
    }

    /*
     * @notice get all founder's pools
     * @return address[] - array of all pool addresses
     */
    function getAllPools() public view returns (address[]) {
        return pool;
    }

    /*
     * @notice returns loan's information
     * @param _debtor_addr - debtor
     * @return uint256 - EFG amount
     * @return uint256 - last timestamp of loan creation or update
     * @return uint256 - last interast rate in EFG
     * @return uint256 - total interest
     * @return address - founder's address
     */
    function getLoanInfo(address _debtor_addr)
        external
        view
        returns (
            bytes8 assetSymbol,
            uint256 amount,
            uint256 timestamp,
            uint256 interestRate,
            uint256 interest,
            address pool
        )
    {
        Loan memory l = debt[_debtor_addr];
        return (l.assetSymbol, l.amount, l.timestamp, l.interestRate, l.interest, l.pool);
    }

    /*
     * @notice returns pool's information
     * @param _pool_addr - founder's address
     * @return bytes8 - pool name
     * @return uint256 - remainingEFG
     */
    function getPoolInfo(address _pool_addr)
        external
        view
        returns (
            bytes32 name,
            uint256 remainingEFG
        )
    {
        Pool memory p = poolsData[_pool_addr];
        return (p.name, p.remainingEFG);
    }

    /*
     * @notice returns amount of locked assets
     * @param _pool_addr - founder's address
     * @param _symbol - token symbol
     * @return uint256 - amount of the collateral , 8 decimals
     */
    function getCollateralInfo(address _pool_addr, bytes8 _symbol) external view returns(uint256) {
        Pool storage p = poolsData[_pool_addr];
        return p.collateral[msg.sender][_symbol];
    }
}
