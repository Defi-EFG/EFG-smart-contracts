pragma solidity ^0.4.25;

import "./lendingInterface.sol"

contract lendingContract is lendingInterface {

address owner;
address oracles[];
mapping (uint256 => uint32) private ecocRate;
uint interestRate, collateralRate;

constructor() {
    owner = msg.sender;

    /* interestRate is the rate per block the borrow must pay back
    * Initial rate is 10% per year
    * Expect blocks per year is 985500
    * 8 decimal places
    * rate per block = annual rate * 1e8 / 985500
    */
    interestRate = 1015 ;
    
    /* Initial collateral rate is 25% , 2 decimal places. */
    collateralRate = 2500; /* 25% */
}

modifier ownerOnly() {
    require(msg.sender==owner);
        _;
    }

modifier oracleOnly() {
    bool exists = false;
    for (uint i =0; i < oracles.length; i++) {
        if (oracles[i] == msg.sender) {
            exists = true;
            break;
        }
    }
    require(exists);
        _;
    }

modifier colletoralOffMargin()  {
        _;
    }
/**
* @notice add or purge oracles, only contract owner
* @param oracle - the address of the oracle to be add or remove
* @param action - a boolean , if true add to list; else remove (if oracle exists)
* @return a boolean , true on success
*/
function authOracles(address oracle, bool action) public ownerOnly() returns (bool);


/**
* @notice get exchange rate , 8 decimal places
* @param timestamp
* @return uint
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