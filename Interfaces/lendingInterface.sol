pragma solidity ^0.4.26;

interface lendingInterface {
/**
* @notice get exchange rate , 8 decimal places
* @param timestamp
* @return rate
*/
function getEcocRate(uint timestamp) view returns (uint);

/**
* @notice set exchnage rate , 8 decimal places, only authorized oracle
* @param timestamp 
* @param rate
* @return bool
*/
function setEcocRate(uint rate, uint timestamp) public oracleOnly() returns (bool);

/**
* @notice set interest rate , 4 decimal places, only contract owner
* @param rate
* @return bool
*/
function setInterestRate(uint rate) public returns (bool);

/**
* @notice get interest rate, 4 decimal places
* @param rate
* @return bool
*/
function getInterestRate() view returns (uint);

/**
* @notice set interest rate , 4 decimal places, only contract owner
* @param rate
* @return bool
*/
function setCollateralRate(uint rate) public ownerOnly() returns (bool);

/**
* @notice get interest rate, 4 decimal places
* @param rate
* @return bool
*/
function getCollateralRate() view returns (uint);

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