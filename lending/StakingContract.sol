pragma solidity 0.4.26;

import "./ECRC20/EFGToken.sol";
import "./ECRC20/GPTToken.sol";

contract StakingContract {
    address owner;
    uint256 mintingRate;
    GPTToken GPT;
    EFGToken EFG;

    mapping(address => uint256) private GPTBalance; /* 8 decimal places */

    constructor (address _EFG_addr,address  _GPT_addr) {
        owner = msg.sender;
        mintingRate = 1286; /* mining rate per second in e-16 */
        GPT = GPTToken(_GPT_addr); /* smart contract address of GPT , 4 decimal places */
        EFG = EFGToken(_EFG_addr); /* smart contract address of EFG , 8 decimal places*/
    }

    struct Minting {
        uint256 lockedAmount; /* EFG, 8 decimales*/
        uint256 lastClaimed ; /* timestamp */
        uint256 mintedAmount; /* 16 decimals */
    }
    mapping(address => Minting) private locked;

    modifier ownerOnly() {
        require(msg.sender == owner);
        _;
    }

     /*
     * @notice return remaing GPT of smart contract , 8 decimal places
     * @return uint256 - the amount of remaining tokens
     */
    function unclaimedGPT(address _beneficiar) public view returns (uint256){
        return GPT.balanceOf(address(this));

    }
    
    /*
     * @notice users can deposit GPT for staking
     * @param _amount - deposit amount of GPT , 8 decimals
     * @return bool - true on success
     */
    function mintGPT(uint256 _amount) returns(bool) {
        /* transfer GPt to this contract - it will fail if not appoved before */
        bool result = EFG.transferFrom(msg.sender, address(this), _amount);
        if (!result) {
            //emit MintGPTEvent(false, msg.sender, _amount);
            return false;
        }

    }

    function claimStakedGPT(address _beneficiar, uint256 _amount) {

    }

    function mintingInfo(address _beneficiar) external view returns (uint256, uint256, uint256) {

    }

}   