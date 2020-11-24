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

    ECRC20 GPT;
    ECRC20 EFG;
    address owner;
    address ownersWallet;
    uint256 requests = 1; /* next available request id */
    uint256 constant pendingPeriod = 21 days;
    uint256 constant mintingRate = 1286; /* minting rate per second in e-16 */
    uint256 rewardFee = 100; /* rate, 4 decimals */
    uint256 ownersFees; /* GPT, 4 decimals */

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
        address beneficiar; /* to whom the withdrawal right belongs */
        uint256 efgAmount; /* 8 decimals */
        uint256 gptAmount; /* 4 decimals */
        uint256 maturity; /* maturity time */
    }
    mapping(uint256 => Pending) private pendingWithdrawals;

    event MintGPTEvent(bool result, address beneficiar, uint EFGAmount);
    event WithdrawEvent(address beneficiar, uint EFGAmount, uint GPTAmount);
    event StopStaking(address minter, uint requestId);

    /**
     * @notice get the current reward fee
     * @return uint - returns the fee, 4 decimal places
     */
    function getRewardFee() public view returns (uint fee) {
        return rewardFee;
    }
    
    /**
     * @notice owner can set a new rate between 0% - 10%
     * @param _fee - new rate , 4 decimals
     * @return bool - true on success
     */
    function setRewardFee(uint256 _fee) external returns (bool result) {
        require(msg.sender == owner);
        require(_fee <= 1000);

        rewardFee = _fee;
        return true;
    }

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
        w.beneficiar = msg.sender;
        m.lockedAmount = 0;
        w.efgAmount = efgBalance;
        m.unclaimedAmount = 0;
        w.gptAmount = gptBalance;
        w.maturity = block.timestamp + pendingPeriod;

        emit StopStaking(msg.sender, requestId);
        return true;
    }

    /**
     * @notice withdraw all EFG and GPT after maturity, beneficiar can withdraw to any address
     * @param _beneficiar - destination address
     * @param _pendingId - requestId of pending withdrawal
     * @return bool - true on success
     */
    function withdraw(address _beneficiar, uint256 _pendingId) external returns(bool result){
        Pending storage w = pendingWithdrawals[_pendingId];
        require((w.beneficiar == msg.sender) && (w.claimed = false));
        w.claimed = true;
        require (w.maturity < block.timestamp);
        require(withdrawEFG(_beneficiar, w.efgAmount));
        uint256 wGPT = w.gptAmount;
        if(unclaimedGPT() > 0) {
            withdrawGPT(_beneficiar, w.gptAmount);
        } else {
            wGPT = 0;
        }

        emit WithdrawEvent(_beneficiar, w.efgAmount, wGPT);
        return true;
    }

    /**
     * @notice withdraw EFG
     * @param _beneficiar - address to send the EFG
     * @param _amount -
     * @return bool - result
     */
    function withdrawEFG(address _beneficiar, uint256 _amount) internal returns(bool result){
        assert(_amount>0);
        return EFG.transfer(_beneficiar, _amount);
    }

    /**
     * @notice withdraw GPT
     * @param _beneficiar - address to send the GPT
     * @param _amount 
     * @return bool - result
     */
    function withdrawGPT(address _beneficiar, uint256 _amount) internal returns(bool result){
        assert(_amount>0);

        uint256 amount;
        uint256 netAmount;
        uint256 withdrawalFee;

        /* get the minimum of the beneficiars balance and smart contract balance of GPT */
        amount = unclaimedGPT();
        if(amount > _amount) {
            amount = _amount;
        }

        (netAmount, withdrawalFee) = computeFee(amount, rewardFee);
        if(GPT.transfer(_beneficiar, netAmount)) {
            ownersFees += withdrawalFee;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @notice returns active minting info  for the beneficiar
     * @param _stakers_addr - _staker's address
     * @return (uint256, uint256, uint256) - returns locked EFG, current GPT amount and last topup timestamp
     */
    function getStakingInfo(address _stakers_addr) external view 
      returns (uint256 EFGamount, uint256 GPTamount, uint256 timestamp) {
        Minting memory m = minter[_stakers_addr];
        return (m.lockedAmount, 
        m.unclaimedAmount + computeUnclaimedAmount((block.timestamp - m.lastClaimed), mintingRate, m.lockedAmount),
        m.lastClaimed);
    }

    /**
     * @notice returns info for pending (or claimed) requests
     * @param _pendingId - id of the request
     * @return bool - if true , the asset are alredy withdrawn
     * @return address - the beneficiar's address
     * @return uint - EFG amount
     * @return uint - GPT amount
     * @return uint - maturity time
     */
     function getPendingInfo(uint _pendingId) external view
       returns (bool claimed, address beneficiar, uint EFGamount, uint GPTamount, uint maturity) {
         Pending memory w = pendingWithdrawals[_pendingId];
         /* check if it exists first */
         require(w.maturity != 0);

         return(w.claimed, w.beneficiar, w.efgAmount, w.gptAmount, w.maturity);
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
     * @notice compute the fee for GPT
     * @param _amount - 4 decimals
     * @param _fee - the fee rate, 4 decimals
     * @return uint256 netAmount - returns the net amount (after fee is substracted)
     * @return uint256 withdrawalFee- returns fee amount
     */
    function computeFee(uint256 _amount, uint256 _fee) internal pure returns (uint256 netAmount, uint256 withdrawalFee) {
        netAmount = ((1e4 - _fee) * _amount)/1e4;
        withdrawalFee = _amount - netAmount;

        return (netAmount, withdrawalFee);
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
