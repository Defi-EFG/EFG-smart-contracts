pragma solidity 0.4.26;

import "ECRC20/EFGToken.sol";
import "ECRC20/GPTToken.sol";

contract lendingContract {
    address owner;
    address pool[];
    EFGToken EFG;
    GPTToken GPT;
    // ECRC20[] asset; /* Token type to inherit transfer() and balanceOf() */
    bytes8[] assetName; /* all ECRC20 token symbols that can be accepted as collateral */
    address[] assetAddress; /* all ECRC20 contract addresses that can be accepted as collateral */
    uint256 secsInYear = 365*24*60*60;

    mapping(address => bool) private oracles;
    mapping(bytes8 => uint256) private collateralRates; /* 4 decimal places */
    mapping(bytes8 => uint256) private EFGRates; /* 8 decimal places */
    mapping(bytes8 => uint256) private interestRates; /* 4 decimal places */
    mapping(address => mapping(bytes8 => uint256)) private balance; /* 8 decimal places for ECOC and all ECRC20 tokens */
    mapping(address => uint256) private EFGBalance; /* 8 decimal places */

    struct Pool {
	bytes32 name;
	mapping(address => mapping(bytes8 => uint256)) private collateral; /* 8 decimal places */
	mapping(address => uint256) private remainingEFG; /* 8 decimal places */
    }
    mapping(address => Pool) private poolsData;
    
    struct Loan {
        uint amount;          /* in EFG , 8 digits */
        uint timestamp;       /* timestamp of last update (creation, topup or repay) */
        uint interestRate;    /* last interast rate in EFG , 6 digits */
        uint xrate;           /* last exchange rate EFG/ECOC , 6 digits */
        uint interest;        /* accumilated interest , 8 digits */
	address pool;         /* pool address */
    }
    mapping(address => Loan) private debt;

    /* Events */
    event depositECOC(bool result, address depositor, uint256 ecoc_amount, address pool, uint256 locked_amount);
    event withdrawECOC(bool result, address beneficiar, uint256 ecoc_amount);
    event withdrawEFG(bool result, address beneficiar, uint256 efg_amount);
    event lockEcoc(bool result, address pool, address borrower, uint256 ecoc_amount, uint256 locked_amount);
    event marginCall(bool result, address pool, address borrower, uint efg_eq_amount);
    event repay(bool result, address debtors_addr, uint256 amount);


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
        require(pool[msg.sender]!=0);
        _;
    }

    modifier oracleOnly() {
        require(oracles[msg.sender]);
        _;
    }

    modifier canSeize(address _debtors_addr) {
        require(msg.sender == owner);
	
        uint totalDebt = getDebt(_debtors_addr);
        uint collateralValue = (collateral[_debtors_addr]["ECOC"] * EFGRates["ECOC"]) / 1e6; /* rate has 6 decimal places */
	uint assetValue;
	// compute the current value of all assets
	for (uint i = 0; i < assetName.length ; i++) {
	    assetValue = (collateral[_debtors_addr][assetName[i]] * EFGRates[assetName[i]]) / 1e6;
	    collateralValue += assetValue;
	}
        require(totalDebt > collateralValue);
        _;
    }


    /*
     * @notice add new asset, only contract owner
     * @param _symbol - the symbol of the asset
     * @param  _contract_addr - smart contract address of the ECRC20
     * @return an uint256 , the current number of ECRC20
     */
    function addNewAsset(bytes8 _symbol, address _contract_addr) external ownerOnly() returns (uint) {
	pool.push(_symbol);
	assetAddress.push(_contract_addr);
	// ECRC20 newToken = ECRC20(_contract_addr);
	// asset.push(newToken);
	return assetAddress.length;
    }

    /*
     * @notice add new pool, only contract owner
     * @param _name - the pool name
     * @param  _leader_addr - address of the depositor(pool leader)
     * @param  _EFG_amount - initial EFG amount for the pool
     * @return an uint256 , the current number of pools
     */
    function addNewPool(bytes8 _name, address _leader_addr, uint _EFG_amount) external ownerOnly() returns (uint) {
	pool.push(_leader_addr);
	Pool storage p = poolsData[_leader_addr];
	p.name = _name;
	p.remainingEFG = _EFG_amount;	
	return poolsData.length;
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
     * @notice get exchange rate , 8 decimal places
     * @param _symbol
     * @return uint - the exchange rate between EFG and the asset
     */
    function getEFGRates(bytes8 _symbol)
        public
        view
        returns (uint256)
    {
        return EFGRates[_symbol];
    }

    /*
     * @notice set exchnage rate , 8 decimal places, only authorized oracle
     * @param _symbol
     * @param _rate
     * @return bool
     */
    function setEFGRate(
			bytes8 _symbol,
			uint256 _rate
			) external oracleOnly() returns (bool) {
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
        require (_rate > 0);
        require (_rate < 10000);
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

    /*
     * @notice Deposit ECOC
     * @param _lock amount of ECOC as collateral(8 decimals), can be zero
     * @return bool
     */
    function depositECOC(uint256 _lock , address _pool_addr) external payable returns (bool) {
        require(msg.value > 0);
        balance[msg.sender]["ECOC"] += msg.value;
        uint256 lock_amount = _lock;
        if (_lock != 0) {
            if (lock_amount > balance[msg.sender]["ECOC"]) {
                lock_amount = balance[msg.sender]["ECOC"];
            }
            bool lock_result = lockECOC(_pool_addr, lock_amount);
            if (!lock_result) {
                emit Locked();
            } else {
                emit Locked();
            }
        }
        return true;
    }

    /*
     * @notice use ECOC as collateral
     * @param _pool_addr address of the pool
     * @param _amount of ECOC as collateral
     * @return bool
     */
    function lockECOC(address _pool_addr, uint256 _amount) public returns (bool) {
        require(_amount >= 0);
        require(_amount <= balance[msg.sender]["ECOC"]);
        /* precision of variables 
        * _amount is 8 decimals
        * collateralRates[] is 4 decimals
        * Loan.xrate is 6 decimals
        * EFGAmount is 8 decimals
        */
        uint EFGAmount = (_amount * collateralRates["ECOC"] * EFGRates["ECOC"]) / 1e12 ;
	    Pool storage p = poolsData[_pool_addr];
	
        balance[msg.sender]["ECOC"] -= _amount;
        collateral[msg.sender]["ECOC"] += _amount;

        Loan storage l = debt[msg.sender];
        /* update interest */
	/* interestRate has 4 decimal places */
        uint lastInterest = (l.amount * l.interestRate * (block.timestamp - l.timestamp))/ (secsInYear * 1e4);
        l.interest += lastInterest;
        
        /* update loan info */
        l.xrate = EFGRates["ECOC"];
        l.interestRate = getInterestRate("ECOC");
        l.timestamp = block.timestamp;
	l.amount += EFGAmount;
	
        EFGBalance[msg.sender] += EFGAmount;
        return true;
    }

    /*
     * @notice get EFG amount of debt
     * @param _debtor
     * @return uint - the EFG amount without the interest
     */
    function getDebt(address _debtor) public view returns (uint256) {
        Loan memory d = debt[_debtor];
    	uint totalDebt = d.amount + d.interest;
    	uint lastInterest = ((block.timestamp - d.timestamp) * getInterestRate("ECOC") ) / (secsInYear * 1e4);
    	totalDebt += lastInterest;
        return totalDebt;
    }

    /*
     * @notice fully or partially repay ECOC
     * @param _amount of EFG to be payed back
     * @return bool
     */
    function repay(uint256 _amount) external returns (bool) {
        require (_amount > 0);
        require (_amount <= EFGBalance[msg.sender]);
        
        Loan storage d = debt[msg.sender];
        
        if (_amount <= d.interest) {
            /* repay the interest first */
            d.interest -= _amount;
            EFGBalance[msg.sender] -= _amount;
            return true;
        }
        
        /* repay amount is greater than interest, decrease the loan */
        uint256 amountLeft = _amount - d.interest;
        d.interest = 0;
        if (d.amount > amountLeft) {
            d.amount -= amountLeft;
            EFGBalance[msg.sender] -= _amount;
            return true;
        } else {
            /* loan repayed in full, release the collateral */
            amountLeft -= d.amount;
            d.amount = 0;
            EFGBalance[msg.sender] -= (_amount + amountLeft) ;
            balance[msg.sender]["ECOC"] += collateral[msg.sender]["ECOC"];
	    collateral[msg.sender]["ECOC"] = 0 ;
	    // also release all other assets
	    for (uint i = 0; i < assetName.length ; i++) {
		balance[msg.sender][assetName[i]] += collateral[msg.sender][assetName[i]];
		collateral[msg.sender][assetName[i]] = 0;
	    }
            return true;
        }
    }

    /*
     * @notice withdraw ECOC
     * @param _amount of ECOC to be withdrawn
     * @return bool
     */
    function withdrawECOC(uint256 _amount, address _beneficiaries_addr) external payable returns (bool) {
        require(_amount > 0);
        require(_amount <= balance[msg.sender]["ECOC"]);
        balance[msg.sender]["ECOC"] -= _amount;
        _beneficiaries_addr.transfer(_amount);
        return true;
    }

    /*
     * @notice withdraw EFG
     * @param _amount of EFG
     * @return bool
     */
    function withdrawEFG(uint256 _amount) external returns (bool) {
        require (_amount > 0);
        require (EFGBalance[msg.sender] >= _amount);
	EFGBalance[msg.sender] -= _amount;
	/* send the tokens */
	EFG.transfer(msg.sender, _amount);
	return true;
    }

    /*
     * @notice margin call, only by contract owner and only on the condition that collateral has fallen short
     * @param _debtors_addr
     * @return bool
     */
    function marginCall(address _debtors_addr) external
        ownerOnly()
        canSeize(_debtors_addr)
        returns (bool) {
	/* seize the collateral */
	collateral[_debtors_addr]["ECOC"] = 0;
	// also seize all other assets
	for (uint i = 0; i < assetName.length ; i++) {
	    collateral[_debtors_addr][assetName[i]] = 0;
	}
	/* reset the loan data */
	Loan storage l = debt[_debtors_addr];
	l.amount = 0;
	l.timestamp = 0;
	l.interestRate = 0;
	l.xrate = 0;
	l.interest =0;

	return true;
    }

    /*
     * @notice display EFG balance
     * @param _address beneficiar's address
     * @return uint256
     */
    function getEFGBalance(address _address) external view returns (uint256){
        return EFGBalance[_address];
    }
}
