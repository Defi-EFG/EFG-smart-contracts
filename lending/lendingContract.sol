pragma solidity 0.4.26;

contract lendingContract {
    address owner;
    address EFGContract;
    address GPTContract;
    uint256 secsInYear = 365*24*60*60;
    uint256 collateralRate;

    mapping(address => bool) private oracles;
    mapping(string => uint256) private EFGRates;
    mapping(string => uint256) private interestRates;
    mapping(address => uint256) private ecocBalance;
    mapping(address => uint256) private collateral;
    mapping(address => uint256) private EFGBalance;


    struct Loan {
        uint amount;          /* in EFG */
        uint timestamp;       /* timestamp of last update (creation, topup or repay) */
        uint interestRate;    /* last interast rate in EFG */
        uint xrate;           /* last exchange rate EFG/ECOC */
        uint interest;        /* accumilated interest */
    }
    mapping(address => Loan) private debt;

    constructor() public {
        owner = msg.sender;
        //address private constant EFG = '0x...';
        //address private constant GPT = '0x...';

        /* interestRate is the rate per year the borrow must pay back
         * Initial rate is 10% per year
         * 2 decimal places (10.00)
         */
        interestRates["ECOC"] = 1000;

        /* Initial collateral rate is 25% , 2 decimal places. */
        collateralRate = 2500;
    }

    modifier ownerOnly() {
        require(msg.sender == owner);
        _;
    }

    modifier oracleOnly() {
        require(oracles[msg.sender]);
        _;
    }

    modifier canSeize(address _debtors_addr) {
        require(msg.sender == owner);
	
        uint totalDebt = getDebt(_debtors_addr);
        uint collateralValue = (collateral[_debtors_addr] * EFGRates['ECOC']) / 1e8; /* rate has 8 decimal places */
        require(totalDebt > collateralValue);
        _;
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
    function getEFGRates(string _symbol)
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
			string _symbol,
			uint256 _rate
			) external oracleOnly() returns (bool) {
        EFGRates[_symbol] = _rate;
        return true;
    }

    /*
     * @notice set interest rate , 2 decimal places, only contract owner
     * @param _symbol
     * @param _interestRate
     * @return bool
     */
    function setInterestRate(string _symbol, uint256 _interestRate)
        external
        ownerOnly()
        returns (bool)
    {
        interestRates[_symbol] = _interestRate;
        return true;
    }

    /*
     * @notice get interest rate, 2 decimal places
     * @param _symbol
     * @return uint - the interest rate of the asset
     */
    function getInterestRate(string _symbol) public view returns (uint256) {
        return interestRates[_symbol];
    }

    /*
     * @notice set collateral rate , 2 decimal places, only contract owner
     * @param _rate
     * @return bool
     */
    function setCollateralRate(uint256 _rate)
        public
        ownerOnly()
        returns (bool)
    {
        /* rate shoude be in range (0-100%) */
        require (_rate > 0);
        require (_rate < 10000);
        collateralRate = _rate;
        return true;
    }

    /*
     * @notice get collateral rate, 2 decimal places
     * @return bool
     */
    function getCollateralRate() public view returns (uint256) {
        return collateralRate;
    }

    /*
     * @notice Deposit ECOC
     * @param _lock amount of ECOC as collateral, can be zero
     * @return bool
     */
    function depositECOC(uint256 _lock) external payable returns (bool) {
        require(msg.value > 0);
        ecocBalance[msg.sender] += msg.value;
        uint256 lock = _lock;
        if (_lock != 0) {
            if (lock > ecocBalance[msg.sender]) {
                lock = ecocBalance[msg.sender];
            }
            lockECOC(lock);
        }
        return true;
    }

    /*
     * @notice use ECOC as collateral
     * @param _amount of ECOC as collateral
     * @return bool
     */
    function lockECOC(uint256 _amount) public returns (bool) {
        require(_amount >= 0);
        require(_amount <= ecocBalance[msg.sender]);
        
        ecocBalance[msg.sender] -= _amount;
        collateral[msg.sender] += _amount;

        Loan storage l = debt[msg.sender];
        /* update interest */
        uint lastInterest = (l.amount * l.interestRate * (block.timestamp - l.timestamp))/ (secsInYear * 1e4); /* rate is in % and has 2 decimal places*/
        l.interest += lastInterest;
        
        /* update loan info */
        l.xrate = EFGRates['ECOC'];
        l.interestRate = getInterestRate('ECOC');        
        l.timestamp = block.timestamp;
        uint EFGAmount = _amount * collateralRate * l.xrate;
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
    	uint lastInterest = ((block.timestamp - d.timestamp) * getInterestRate('ECOC') ) / (secsInYear * 1e4);
    	totalDebt += lastInterest;
        return totalDebt;
    }

    /*
     * @notice fully or partially payback ECOC
     * @param _amount of EFG to be payed back
     * @return bool
     */
    function payback(uint256 _amount) external returns (bool) {
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
            ecocBalance[msg.sender] += collateral[msg.sender] ;
            collateral[msg.sender] = 0 ;
            return true;
        }
    }

    /*
     * @notice withdraw ECOC
     * @param _amount of ECOC to be withdrawn
     * @return bool
     */
    function withdrawEcoc(uint256 _amount, address _beneficiaries_addr) external payable returns (bool) {
        require(_amount > 0);
        require(_amount <= ecocBalance[msg.sender]);
        ecocBalance[msg.sender] -= _amount;
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
	collateral[_debtors_addr] = 0;
	/* reset the loan data */
	Loan storage l = debt[_debtors_addr];
	l.amount = 0;
	l.timestamp = 0;
	l.interestRate = 0;
	l.xrate =
	    l.interest =0;

	return true;
    }
}
