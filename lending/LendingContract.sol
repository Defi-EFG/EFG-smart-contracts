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
    uint256 secsIn7Hours = 7 * 60 * 60;
    uint256 private interestRateEFG; /* 4 decimal places */
    uint256 constant private periodRate = 5; /* portion of debt in GPT to get the 7 hours grace period , 2 decimal places (5%) */
    uint256 constant private margin = 40; /* margin for activating liquidation , 2 decimal places (10%) */

    mapping(address => bool) private oracles;
    mapping(bytes8 => uint256) private collateralRates; /* 4 decimal places */
    mapping(bytes8 => uint256) private USDTRates; /* 6 decimal places */
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
        uint256 lastGracePeriod; /* */
        uint256 remainingGPT; /* GPT left */
        address poolAddr; /* pool address */
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
    event WithdrawGPTEvent(bool result, address beneficiar, uint256 gpt_amount);
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
    event ExtendGracePeriodEvent(bool result, address debtors_addr, uint256 amount);

    constructor(address _EFG_addr, address _GPT_addr) public {
        owner = msg.sender;
        EFG = EFGToken(_EFG_addr); /* smart contract address of EFG */
        GPT = GPTToken(_GPT_addr); /* smart contract address of GPT */

        /* interestRate is the rate per year the borrow must pay back
         * Initial rate is 10% per year
         * 4 decimal places (1,000/10,000=0.1=10%)
         */
        interestRateEFG = 1000;

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
        address poolAddress = l.poolAddr;
        require(msg.sender == poolAddress) ;
        /* get total debt*/
        uint256 totalDebt;
        (totalDebt,) = getDebt(_debtors_addr);
        /* compute current collateral value for this asset*/
        Pool storage p = poolsData[poolAddress];
        uint256 collateralValue = (p.collateral[_debtors_addr][l.assetSymbol] *
            computeEFGRate(USDTRates[l.assetSymbol], USDTRates["EFG"])) / 1e6; /* rate has 6 decimal places */

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

    /**
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

    /**
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

    /**
     * @notice get exchange rate of asset/USDT , 6 decimal places
     * @param _symbol - asset's symbol
     * @return uint - the exchange rate between EFG and the asset
     */
    function getUSDTRates(bytes8 _symbol) public view returns (uint256) {
        return USDTRates[_symbol];
    }

    /**
     * @notice set exchnage rate of asset/USDT, 6 decimal places, only authorized oracle
     * @param _symbol - asset's symbol
     * @param _rate - rate (asset/USDT)
     * @return bool
     */
    function setUSDTate(bytes8 _symbol, uint256 _rate)
        external
        oracleOnly()
        returns (bool)
    {
        USDTRates[_symbol] = _rate;
        return true;
    }

    /**
     * @notice set interest rate , 4 decimal places, only contract owner
     * @param _interestRate - interest rate on EFG
     * @return bool
     */
    function setInterestRate(uint256 _interestRate)
        external
        ownerOnly()
        returns (bool)
    {
        interestRateEFG = _interestRate;
        return true;
    }

    /**
     * @notice get interest rate, 4 decimal places
     * @return uint - the interest rate of EFG
     */
    function getInterestRate() external view returns (uint256) {
        return interestRateEFG;
    }

    /**
     * @notice set collateral rate , 4 decimal places, only contract owner
     * @param _symbol - asset's symbol
     * @param _rate - borrow power of the asset
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

    /**
     * @notice get collateral rate, 4 decimal places
     * @param _symbol -asset's symbol
     * @return bool
     */
    function getCollateralRate(bytes8 _symbol) public view returns (uint256) {
        return collateralRates[_symbol];
    }

    /* fallback not payable, don't accept ECOC deposits directly; throw the transaction */
    function() external {}

    /**
     * @notice Deposit ECOC
     * @param _pool_addr - pool address
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
    
    /**
     * @notice Deposit ECRC20
     * @param _symbol - asset symbol
     * @param _amount - amount of ECRC tokens
     * @param _pool_addr - address of pool owner
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

    /**
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
            computeEFGRate(USDTRates[_symbol], USDTRates["EFG"])) / 1e10;
        require(EFGAmount <= p.remainingEFG);

        /* save loan info */
        if (loanIsNew) {
            l.assetSymbol = _symbol;
            l.xrate = computeEFGRate(USDTRates[_symbol], USDTRates["EFG"]);
            l.interestRate = interestRateEFG;
            l.interest = 0;
            l.poolAddr = _pool_addr;
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

    /**
     * @notice used by borrow() function to avoid stack too deep problem
     * @param _symbol - asset symbol
     * @param _amount - amount of asset
     * @param _pool_addr - pool where the loan belongs
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
        if (USDTRates[_symbol] == 0) {
            return false;
        }

        Pool storage p = poolsData[_pool_addr];
        if (_amount > p.collateral[msg.sender][_symbol]) {
            return false;
        }

        (uint256 currentDebt, ) = getDebt(msg.sender);
        uint256 borrowPower = ((p.collateral[msg.sender][_symbol] - _amount) *
            collateralRates[_symbol]) / 1e4;
        return ((borrowPower * computeEFGRate(USDTRates[_symbol], USDTRates["EFG"])) / 1e6 > currentDebt);
    }

    /**
     * @notice get EFG amount of debt
     * @param _debtor - debtor's address
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
        return (totalDebt, d.poolAddr);
    }

    /**
     * @notice fully or partially repay ECOC
     * @param _amount of EFG to be payed back
     * @return bool
     */
    function repay(uint256 _amount) external returns (bool) {
        require(_amount > 0);
        require(_amount <= EFGBalance[msg.sender]);

        Loan storage d = debt[msg.sender];
        require(d.amount !=0 );
        Pool storage p = poolsData[d.poolAddr];

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
            /* reset loan data */
            d.assetSymbol = "";
            d.timestamp = 0;
            d.interestRate = 0;
            d.xrate = 0;
            d.interest = 0;
            d.lastGracePeriod = 0;
            d.remainingGPT = 0;
            d.poolAddr = address(0x0);

            return true;
        }
    }

    /**
     * @notice withdraw ECOC
     * @param _amount of ECOC to be withdrawn
     * @param _beneficiars_addr - withdrawal address
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

    /**
     * @notice withdraw EFG
     * @param _amount - EFG amount
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
    
    /**
     * @notice withdraw Asset (ECRC20)
     * @param _amount - amount of asset to be withdrawn
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

    /**
     * @notice margin call, only by pool owner and only on the condition that collateral has fallen short
     * @param _debtors_addr - address of debtor
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
        Pool storage p = poolsData[l.poolAddr];
        balance[l.poolAddr][l.assetSymbol] +=  p.collateral[_debtors_addr][l.assetSymbol];

         emit  MarginCallEvent(l.poolAddr, _debtors_addr, l.assetSymbol,
            p.collateral[_debtors_addr][l.assetSymbol]);

        p.collateral[_debtors_addr][l.assetSymbol] = 0;
        /* reset the loan data */
        l.assetSymbol = "";
        l.amount = 0;
        l.timestamp = 0;
        l.interestRate = 0;
        l.xrate = 0;
        l.interest = 0;
        l.lastGracePeriod = 0;
        l.remainingGPT = 0;
        l.poolAddr = address(0x0);

        return true;
    }

    /**
     * @notice deposit GPT to extend Grace Period
     * @param _gpt_amount - amount of GPT to consume. If zero ,
     * still can trigget the protection if enough GPT left from the previosu use
     * @return bool - true on success, else false
     */
    function extendGracePeriod(uint256 _gpt_amount) external returns(bool) {
        /* check if loan exists*/
        Loan storage l = debt[msg.sender];
        if (l.amount == 0) {
            emit ExtendGracePeriodEvent(false, msg.sender , 0);
            return false;
        }

        /* check if GPT is enough to activate the grace period */
        (uint256 totalDebt,) = getDebt(msg.sender);
        uint256 GPTRate = computeEFGRate(USDTRates["GPT"], USDTRates["EFG"]);
        if (totalDebt * periodRate / 1e2 > (l.remainingGPT + _gpt_amount) * GPTRate / 1e6) {
            emit ExtendGracePeriodEvent(false, msg.sender , 0);
            return false;
        }

        if (_gpt_amount != 0) {
            /* deposit GPT  - it will fail if not appoved before */
            bool result = GPT.transferFrom(msg.sender, address(this), _gpt_amount);
            if (!result) {
                emit ExtendGracePeriodEvent(false, msg.sender, _gpt_amount);
                return false;
            } else {
                l.remainingGPT += _gpt_amount;
            }
        }

        /* trigger the protection */
        /* check if the last period expired or not;
           if not, include the remaining time to the new period*/
        uint256 period = secsIn7Hours;
        if (block.timestamp - l.lastGracePeriod < secsIn7Hours) {
            period += (block.timestamp - l.lastGracePeriod);
        }

        /* update loan data*/
        l.lastGracePeriod = block.timestamp;
        l.remainingGPT -= (totalDebt * periodRate / GPTRate) * 1e4; /* 1e6 * 1e-2*/
        emit ExtendGracePeriodEvent(false, msg.sender, _gpt_amount);

       return true;
    }

    /**
     * @notice withdraw GPT , owner only, can withdraw to any address
     * @param _beneficiar - destination address
     * @param _amount - amount of GPT to withdrawn. If it is set to zero then  withdraw total balance
     * @return bool - true on success, else false
     */
    function withdrawGPT(address _beneficiar, uint256 _amount) external ownerOnly() returns(bool){
        require(GPT.balanceOf(address(this)) > 0);
        uint256 requestedAmount = _amount;
        if ((_amount == 0) || ((_amount > GPT.balanceOf(address(this))))) {
            requestedAmount = GPT.balanceOf(address(this));
        }

        /* send the GPT tokens */
        bool result = GPT.transfer(_beneficiar, _amount);
        if(!result) {
            emit WithdrawGPTEvent(false, msg.sender, _amount);
            return false;
        } else {
            emit WithdrawGPTEvent(true, _beneficiar, _amount);
            return true;
        }
    }

    /**
     * @notice display EFG balance
     * @param _address beneficiar's address
     * @return uint256
     */
    function getEFGBalance(address _address) external view returns (uint256) {
        return EFGBalance[_address];
    }

    /**
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

    /**
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
            address poolAddr
        )
    {
        Loan memory l = debt[_debtor_addr];
        return (l.assetSymbol, l.amount, l.timestamp, l.interestRate, l.interest, l.poolAddr);
    }

    /**
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

    /**
     * @notice returns amount of locked assets
     * @param _pool_addr - founder's address
     * @param _symbol - token symbol
     * @return uint256 - amount of the collateral , 8 decimals
     */
    function getCollateralInfo(address _pool_addr, bytes8 _symbol) external view returns(uint256) {
        Pool storage p = poolsData[_pool_addr];
        return p.collateral[msg.sender][_symbol];
    }

     /**
     * @notice computes asset/EFG rate
     * @param _assetRate - asset/USDT
     * @param _EFGRate - EFG/USDT
     * @return uint256 - amount of the collateral , 6 decimals
     */
    function computeEFGRate(uint256 _assetRate, uint256 _EFGRate) internal pure returns(uint256) {
        uint256 assetToEFG;
        require((_EFGRate > 0) && (_assetRate > 0));

        assetToEFG = (_assetRate * 1e6 )/ _EFGRate; /* 6 decimal places */
        return assetToEFG;
    }
}
