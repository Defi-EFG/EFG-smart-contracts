pragma solidity ^0.4.25;

import "./lendingInterface.sol"

contract lendingContract is lendingInterface {

address owner;
mapping (address => bool) private oracles;
mapping (string => mapping(uint256 => uint256)) private EFGRate;
mapping (string => uint256) private InterestRate;
uint collateralRate;

constructor() {
    owner = msg.sender;

    /* interestRate is the rate per block the borrow must pay back
    * Initial rate is 10% per year
    * Expect blocks per year is 985500
    * 8 decimal places
    * rate per block = annual rate * 1e8 / 985500
    */
    interestRate['ECOC'] = 1015 ;
    
    /* Initial collateral rate is 25% , 2 decimal places. */
    collateralRate = 2500; /* 25% */
}

modifier ownerOnly() {
    require(msg.sender==owner);
        _;
    }

modifier oracleOnly() {
    require(oracle[msg.sender]);
        _;
    }

modifier colletoralOffMargin()  {
     require(msg.sender==owner);
     /* implement the check for margin call below */
     require(false);
        _;
    }
/**
* @notice add or purge oracles, only contract owner
* @param oracleAddr - the address of the oracle to be add or remove
* @param action - a boolean , if true add to list; else unauthorize
* @return a boolean , true on success
*/
function authOracles(address _oracleAddr, bool _action) public ownerOnly() returns (bool) {
    oracles[_oracleAddr]=_action;
    return true;
}


/**
* @notice get exchange rate , 8 decimal places
* @param symbol
* @param timestamp
* @return uint
*/
function getEFGRates(string _symbol, uint _timestamp) view returns (uint) {
    return EFGRate[_symbol][_timestamp];
}

/**
* @notice set exchnage rate , 8 decimal places, only authorized oracle
* @param symbol
* @param timestamp 
* @param rate
* @return bool
*/
function setEFGRate(string symbol, uint timestamp, uint rate) external oracleOnly() returns (bool){
    EFGRate[_symbol][_timestamp] = _rate;
    return true;
}

/**
* @notice set interest rate , 8 decimal places, only contract owner
* @param _symbol
* @param _interestRate
* @return bool
*/
function setInterestRate(string _symbol, uint _interestRate) external ownerOnly() returns (bool) {
    interestRate[_symbol] = _interestRate;
    return true;
}

/**
* @notice get interest rate, 8 decimal places
* @param _symbol
* @return uint - the interest rate of the asset
*/
function getInterestRate(string _symbol) view returns (uint) {
    return interestRate[_symbol];
}

/**
* @notice set interest rate , 8 decimal places, only contract owner
* @param rate
* @return bool
*/
function setCollateralRate(uint _rate) public ownerOnly() returns (bool){
    collateralRate = _rate;
    return true;
}

/**
* @notice get interest rate, 8 decimal places
* @param rate
* @return bool
*/
function getCollateralRate() view returns (uint){
    return collateralRate;
}

/**
* @notice Deposit collateral
* @param amount of ECOC as collateral
* @return bool
*/
function depositCollateral(uint amount) returns (bool);

/**
* @notice fully or partially payback ECOC
* @param amount of EFG to be payed back
* @return bool
*/
function payback(uint amount) returns (bool);

/**
* @notice withdraw ECOC
* @param amount of ECOC to be withdrawn
* @return bool
*/
function withdrawEcoc(uint amount) returns (bool);

/**
* @notice withdraw EFG
* @param amount of EFG
* @return bool
*/
function withdrawToken(uint amount) returns (bool);

/**
* @notice margin call, only by contract owner and only on condition that colletoral has fallen short
* @param amount of ECOC
* @return bool
*/
function marginCall(address debtor_addr, uint amount) ownerOnly() colletoralOffMargin() returns (bool);

}