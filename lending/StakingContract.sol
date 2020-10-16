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
        uint256 unclaimedAmount; /* 16 decimals */
    }
    mapping(address => Minting) private locked;

    modifier ownerOnly() {
        require(msg.sender == owner);
        _;
    }

    event MintGPTEvent(bool result, address beneficiar, uint EFGAmount);
    
    /*
     * @notice users can deposit EFG for staking
     * @param _amount - deposit amount of EFG , 8 decimals
     * @return bool - true on success , else false
     */
    function mintGPT(uint256 _amount) returns(bool) {
        require(_amount > 0);
        /* check if contract still  has GPT */
        if (unclaimedGPT() == 0) {
            emit MintGPTEvent(false, msg.sender, _amount);
            return false;
        }
        /* transfer EFG to this contract - it will fail if not appoved before */
        bool result = EFG.transferFrom(msg.sender, address(this), _amount);
        if (!result) {
            emit MintGPTEvent(false, msg.sender, _amount);
            return false;
        }

        /* create or update the minting info */
        Minting storage m = locked[msg.sender];

        if(m.lockedAmount > 0) {
            /* this is a topup*/
            updateUnclaimedAmount(msg.sender);
        }
        m.lockedAmount += _amount;
        m.lastClaimed = block.timestamp;

        emit MintGPTEvent(true , msg.sender, _amount);
        return true;
    }

    /*
     * @notice claim any unclaimed GPT (withdraw)
     * @param _beneficiar - destination address
     * @return bool - true on success
     */
    function claimStakedGPT(address _beneficiar) {

    }

    /*
     * @notice withdraw EFG , beneficiar can withdraw to any address
     * @param _beneficiar - destination address
     * @param _amount - amount of EFG to withdrawn
     * @return bool - true on success
     */
    function withdrawEFG(address _beneficiar, uint256 _amount) returns (bool){

    }

    /*
     * @notice returns mining info for the beneficiar
     * @param _beneficiar
     * @return (uint256, uint256, uint256) - returns locked EFG, last topup timestamp and unclaimed amount
     */
    function mintingInfo(address _beneficiar) external view returns (uint256, uint256, uint256) {
        Minting memory m = locked[_beneficiar];
        return (m.lockedAmount, m.lastClaimed, m.unclaimedAmount);
    }

    /*
     * @notice return remaing GPT of smart contract , 4 decimal places
     * @return uint256 - the amount of remaining tokens
     */
    function unclaimedGPT() public view returns (uint256){
        return GPT.balanceOf(address(this));
    }

    /*
     * @notice updates the total staked GPT amount in a minting contract
     * @rparam _minters_addr
     */
    function updateUnclaimedAmount(address _minters_addr) internal {
        Minting storage m = locked[msg.sender];
        m.unclaimedAmount += computeUnclaimedAmount((block.timestamp - m.lastClaimed), mintingRate, m.lockedAmount);
        return ;
    }


    function computeUnclaimedAmount(uint _period, uint _rate, uint _staked) internal pure returns(uint256) {
        uint256 stakedAmount;

        stakedAmount = _period * _rate * _staked;
        stakedAmount /= 1e16; /* staking rate is in e-16 */

        return stakedAmount;
    }
}