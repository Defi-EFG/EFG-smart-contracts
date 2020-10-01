pragma solidity ^0.4.25;

contract lendingContract {
    address owner;
    uint256 secsInYear = 365*24*60*60;
    uint256 collateralRate;

    mapping(address => bool) private oracles;
    mapping(string => uint256) private EFGRates;
    mapping(string => uint256) private interestRates;
    mapping(address => uint256) private ecocBalance;
    mapping(address => uint256) private collateral;

    struct Loan {
        uint amount;
        uint timestamp;
        uint interestRate;
        uint xrate;
    }
    mapping(address => Loan) private debt;

    constructor() public {
        owner = msg.sender;

        /* interestRate is the rate per block the borrow must pay back
         * Initial rate is 10% per year
         * Expect blocks per year is 985500
         * 8 decimal places
         * rate per block = annual rate * 1e8 / 985500
         */
        interestRates["ECOC"] = 1015;

        /* Initial collateral rate is 25% , 2 decimal places. */
        collateralRate = 2500; /* 25% */
    }

    modifier ownerOnly() {
        require(msg.sender == owner);
        _;
    }

    modifier oracleOnly() {
        require(oracles[msg.sender]);
        _;
    }

    modifier colletoralOffMargin(_debtors_addr) {
        require(msg.sender == owner);
        /* implement the check for margin call below */
        /* x0, xc, s, r, t0, tc
            allow liquidation when:
        xc< xo*s*(1+r(tc-t0)/(1 year in seconds))*/
        Loan l = debt[_debtors_addr];
        uint256 x0 = l.xrate;
        uint256 xc = getEFGRates('ECOC');
        uint256 s = collateralRate;
        uint256 r = l.interestRate;
        uint256 t0 = l.timestamp;
        uint256 tc = block.timestamp;

        require(xc<s*x0*(1+(r*(tc-t0)/secsInYear))); /* todo: include the decimal places in calculation*/
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
     * @notice set interest rate , 8 decimal places, only contract owner
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
     * @notice get interest rate, 8 decimal places
     * @param _symbol
     * @return uint - the interest rate of the asset
     */
    function getInterestRate(string _symbol) public view returns (uint256) {
        return interestRates[_symbol];
    }

    /*
     * @notice set interest rate , 8 decimal places, only contract owner
     * @param _rate
     * @return bool
     */
    function setCollateralRate(uint256 _rate)
        public
        ownerOnly()
        returns (bool)
    {
        collateralRate = _rate;
        return true;
    }

    /*
     * @notice get interest rate, 8 decimal places
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
        if (_lock != 0) {
            lockECOC(_lock);
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
        collateral[msg.sender] += _amount;

        Loan storage l = debt[msg.sender];
        uint interest = l*l.interestRate;
        l.xrate = EFGRates['ECOC'];
        l.amount += _amount * l.xrate;
        l.timestamp += block.timestamp;
        l.interestRate = getInterestRate('ECOC');
        return true;
    }

    /*
     * @notice get EFG amount of debt
     * @param _debtor
     * @return uint - the EFG amount without the interest
     */
    function getDebt(address _debtor) public view returns (uint256) {
        return debt[_debtor];
    }

    /*
     * @notice fully or partially payback ECOC
     * @param amount of EFG to be payed back
     * @return bool
     */
    function payback(uint256 amount) returns (bool);

    /*
     * @notice withdraw ECOC
     * @param _amount of ECOC to be withdrawn
     * @return bool
     */
    function withdrawEcoc(uint256 _amount) external returns (bool) {
        require(_amount > 0);
        require(_amount <= ecocBalance[msg.sender]);
        ecocBalance[msg.sender] -= msg.value;
        address.(this).send(_amount);
        return true;
    }

    /*
     * @notice withdraw EFG
     * @param amount of EFG
     * @return bool
     */
    function withdrawEFG(uint256 amount) returns (bool);

    /*
     * @notice margin call, only by contract owner and only on condition that colletoral has fallen short
     * @param amount of ECOC
     * @return bool
     */
    function marginCall(address debtor_addr, uint256 amount)
        ownerOnly()
        colletoralOffMargin()
        returns (bool);
}
