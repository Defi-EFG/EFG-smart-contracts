pragma solidity ^0.4.20;

contract ECRC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract StakingContract {

    /* new function for implementation*/
    // function getPendingIdsaddress (address _stakers_addr) external view returns (uint[] pendingId);
    // function getPendingInfo(uint pendingId) external view returns (uint EFGamount, uint GPTamount, uint timestamp);
    // function getStakingInfo(address _stakers_addr) external view returns (uint EFGamount, uint GPTamount, uint timestamp);
    // function stopStaking() external returns (bool result);
    // withdraw(uint pendingId) returns (bool result);  (withdraw must has pending id as an arg)

    ECRC20 GPT;
    ECRC20 EFG;
    address owner;
    address ownersWallet;
    uint256 requests = 1; /* next available request id */
    uint256 constant pendingPeriod = 21 days;
    uint256 constant mintingRate = 1286; /* minting rate per second in e-16 */
    uint256 rewardFee = 100; /* 4 decimals */

    function StakingContract (address _EFG_addr,address  _GPT_addr, address _ownersWallet) public {
	    owner = msg.sender;
        GPT = ECRC20(_GPT_addr); /* smart contract address of GPT , 4 decimal places */
        EFG = ECRC20(_EFG_addr); /* smart contract address of EFG , 8 decimal places*/
	    ownersWallet = _ownersWallet; /* for the fee */
    }

    struct Minting {
        uint256[] pendingRequests;
        uint256 lockedAmount; /* EFG, 8 decimales*/
        uint256 lastClaimed ; /* timestamp */
        uint256 unclaimedAmount; /* 4 decimals */
    }
    mapping(address => Minting) private minter;

    struct Pending {
        bool claimed; /* if already withdrawn or not */
        uint256 efgAmount; /* 8 decimals */
        uint256 gptAmount; /* 4 decimals */
        uint256 timestamp; /* maturity time */
    }
    mapping(uint256 => Pending) private pendingWithdrawals;

    event MintGPTEvent(bool result, address beneficiar, uint EFGAmount);
    event WithdrawEFGEvent(bool result, address beneficiar, uint EFGAmount);
    event StopStaking(address minter, uint requestId);
    
    /**
     * @notice users can deposit EFG for staking
     * @param _amount - deposit amount of EFG , 8 decimals
     * @return bool - true on success , else false
     */
    function mintGPT(uint256 _amount) external returns(bool result) {
        require(_amount > 0);
        /* check if contract still has GPT */
        if (unclaimedGPT() == 0) {
            emit MintGPTEvent(false, msg.sender, _amount);
            return false;
        }
        /* transfer EFG to this contract - it will fail if not appoved before */
        result = EFG.transferFrom(msg.sender, address(this), _amount);
        if (!result) {
            emit MintGPTEvent(false, msg.sender, _amount);
            return false;
        }

        /* create or update the minting info */
        Minting storage m = minter[msg.sender];

        if(m.lockedAmount > 0) {
            /* this is a topup*/
            updateUnclaimedAmount(msg.sender);
        }
        m.lockedAmount += _amount;
        m.lastClaimed = block.timestamp;

        emit MintGPTEvent(true , msg.sender, _amount);
        return true;
    }

    /**
     * @notice request staking - EFG and GPT will be feezed for 21 days
     * @return bool - true on success
     */
    function stopStaking() external returns (bool result) {
        Minting storage m = minter[msg.sender];
        require(m.lockedAmount>0);
        /* get the next available ID */
        requests++;
        uint requestId = requests-1;
        uint efgBalance = m.lockedAmount;
        uint gptBalance = m.unclaimedAmount + computeUnclaimedAmount((block.timestamp - m.lastClaimed), mintingRate, m.lockedAmount);
        Pending storage w = pendingWithdrawals[requestId];
        m.pendingRequests.push(requestId);
        w.claimed = false;
        m.lockedAmount = 0;
        w.efgAmount = efgBalance;
        m.unclaimedAmount = 0;
        w.gptAmount = gptBalance;
        w.timestamp = block.timestamp + pendingPeriod;

        emit StopStaking(msg.sender, requestId);
        return true;
    }

    /**
     * @notice withdraw EFG , beneficiar can withdraw to any address
     * @param _beneficiar - destination address
     * @param _amount - amount of EFG to withdrawn
     * @return bool - true on success
     */
    function withdrawEFG(address _beneficiar, uint256 _amount) external returns(bool result){
        Minting storage m = minter[msg.sender];
        require(_amount <= m.lockedAmount);
        
        /* send the tokens */
        result = EFG.transfer(_beneficiar, _amount);
        if(!result) {
            emit WithdrawEFGEvent(false, msg.sender, _amount);
            return false;
        }

        updateUnclaimedAmount(msg.sender);
        m.lockedAmount -= _amount;
        m.lastClaimed = block.timestamp;
        emit WithdrawEFGEvent(true, _beneficiar, _amount);

        return true;
    }

    /**
     * @notice returns mining info for the beneficiar
     * @param _beneficiar - beneficiar's address
     * @return (uint256, uint256, uint256) - returns locked EFG, last topup timestamp and unclaimed amount
     */
    function mintingInfo(address _beneficiar) external view returns(uint256 lockedEFG, uint256 lastTimestamp, uint256 unclaimedAmount) {
        Minting memory m = minter[_beneficiar];
        return (m.lockedAmount, m.lastClaimed, m.unclaimedAmount + computeUnclaimedAmount((block.timestamp - m.lastClaimed), mintingRate, m.lockedAmount));
    }

    /**
     * @notice return remaing GPT of smart contract , 4 decimal places
     * @return uint256 - the amount of remaining tokens
     */
    function unclaimedGPT() public view returns(uint256 contractGPTBalance){
        return GPT.balanceOf(address(this));
    }

    /**
     * @notice updates the total staked GPT amount in a minting contract
     * @param _minters_addr - address of minter
     */
    function updateUnclaimedAmount(address _minters_addr) internal {
        Minting storage m = minter[_minters_addr];
        m.unclaimedAmount += computeUnclaimedAmount((block.timestamp - m.lastClaimed), mintingRate, m.lockedAmount);
        return ;
    }

    /**
     * @notice for computing the staked amount of last period only (pure function)
     * @param _period -
     * @param _rate -
     * @param _staked -
     * return uint256 - the amount of unclaimed GPT
     */

    function computeUnclaimedAmount(uint _period, uint _rate, uint _staked) internal pure returns(uint256) {
        uint256 stakedAmount;
        
        stakedAmount = _period * _rate * _staked;
        stakedAmount /= 1e16; /* staking rate is in e-16 */
        
        return stakedAmount;
    }
}
