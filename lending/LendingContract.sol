pragma solidity ^0.4.20;

contract ECRC20 {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);
    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

contract LendingContract {
    address owner;
    address ownerWallet;
    address[] pool;  /* pool leader addresses */
    ECRC20 EFG;
    ECRC20 GPT;
    ECRC20[] asset; /* Token type to inherit transfer() and balanceOf() */
    bytes8[] assetName; /* all ECRC20 token symbols that can be accepted as collateral */
    address[] assetAddress; /* all ECRC20 contract addresses that can be accepted as collateral */
    uint256 constant secsInDay = 24 * 60 * 60;
    uint256 constant secsIn7Hours = 7 * 60 * 60;
    uint256 private interestRateEFG; /* 4 decimal places */
    uint256 constant private periodRate = 5; /* portion of debt in GPT to get the 7 hours grace period , 2 decimal places (5%) */

    mapping(address => bool) private oracles;
    mapping(bytes8 => uint256) private collateralRates; /* 4 decimal places */
    mapping(bytes8 => uint256) private USDTRates; /* 6 decimal places */
    mapping(address => address) private usersPool; /* in which pool the user deposited his collaterals */
    mapping(address => mapping(bytes8 => uint256)) private balance; /* 8 decimal places for ECOC and all ECRC20 tokens */
    mapping(address => uint256) private EFGBalance; /* 8 decimal places */

    /* statistics */
    uint256 totalInterestAmount = 0;
    uint256 totalLiqudatedEFGEq = 0;
    uint256 totalConsumedGPT = 0;
    
    struct Pool {
        bytes32 name;
	address[] members;
        mapping(address => mapping(bytes8 => uint256)) collateral; /* 8 decimal places */
	uint256 capital; /* 8 decimal places */
        uint256 remainingEFG; /* 8 decimal places */
    }
    mapping(address => Pool) private poolsData;

    struct Loan {
        bool locked; /* while locked, the loan is in use. Debtor can't add or withdraw any collateral */
	bool protectionUsed; /* if grace period already used once */
        bytes8[] assetSymbol; /* can be ECOC or any ECRC20 */
        mapping(bytes8 => uint256) deposits; /* deposited collateral for this loan */
        uint256 EFGamount; /* amount in EFG , 8 digits */
        uint256 timestamp; /* timestamp of last update (creation or partial repay) */
        uint256 interestRate; /* Initial interest rate (depends on asset), 6 digits */
        uint256[] collateralRate; /* Initial collateral rate of assets , 4 digits */
        uint256 xrate; /* Initial exchange rate EFG/assetSymbol , 6 digits */
        uint256 interest; /* accumilated interest , 8 digits */
        uint256 lastGracePeriod; /* timestamp of last trigger of grace period*/
        uint256 remainingGPT; /* GPT left , 4 digits */
        address poolAddr; /* pool address */
    }
    mapping(address => Loan) private debt;

    /* Events */
    event IncreaseCapitalEvent(bool result, address pool_founder, uint256 EFG_amount);
    event DepositECOCEvent(address depositor, uint256 ecoc_amount);
    event DepositAssetEvent(bool result, bytes8 _symbol, address depositor, uint256 _amount);
    event WithdrawECOCEvent(
        address user_account,
        address beneficiar,
        uint256 ecoc_amount
    );
    event WithdrawEFGEvent(address beneficiar, uint256 efg_amount);
    event WithdrawGPTEvent(bool result, address beneficiar, uint256 gpt_amount);
    event WithdrawAssetEvent(bool result, address beneficiar, bytes8 symbol, uint256 _amount);
    event BorrowEvent(
        bool newLoan,
        address pool,
        address borrower,
        uint256 EFG_amount
    );
    event MarginCallEvent(
        address pool,
        address borrower
    );
    event RepayEvent(bool fullyRepaid, address debtors_addr, uint256 amount);
    event ExtendGracePeriodEvent(address debtors_addr, uint256 amount);

    function LendingContract(address _EFG_addr, address _GPT_addr, address _ownerWallet) public {
        owner = msg.sender;
	ownerWallet = _ownerWallet;
        EFG = ECRC20(_EFG_addr); /* smart contract address of EFG */
        GPT = ECRC20(_GPT_addr); /* smart contract address of GPT */

        /* interestRate is the rate per year the borrow must pay back
         * Initial rate is 0.03% per day
         * 4 decimal places (3/10,000=0.0003=0.03%)
         */
        interestRateEFG = 3;

        /* Initial collateral rate of ECOC is 60% , 4 decimal places. */
        collateralRates["ECOC"] = 6000;
    }

    modifier ownerOnly() {
        require(msg.sender == owner);
        _;
    }

    modifier poolOwnerOnly() {
        require(!(addressSearch(pool, msg.sender) == -1 ));
        _;
    }

    modifier poolExists(address _pool_addr) {
         require(!(addressSearch(pool, _pool_addr) == -1 ));
        _;
    }
    
    modifier oracleOnly() {
        require(oracles[msg.sender]);
        _;
    }

    /**
     * @notice check if the loan can be liquidated
     * @param  _debtors_addr - address of the debtor
     * @return an bool , if true then the loan is liquidable
     */
    function canSeize(address _debtors_addr) public view returns (bool seizable) {
        /* check if a loan exists */
        Loan storage l =  debt[_debtors_addr];
	if (l.EFGamount == 0) {
	    return false;
	}
        /* check if grace period is still running */
	if(block.timestamp < l.lastGracePeriod) {
	    return false;
	}
        /* get total debt*/
        uint256 totalDebt;
        (totalDebt,) = getDebt(_debtors_addr);
        /* compute current collateral value for this asset*/
	if (totalDebt > computeCollateralValue(_debtors_addr) ) {
	    return true;
	}
	return false;
    }

    /**
     * @notice add or update new asset, only contract owner
     * @param _symbol - the symbol of the asset
     * @param  _contract_addr - smart contract address of the ECRC20
     * @param _collateral_rate - rate for the symbol , 4 digits
     * @return an uint256 , the current number of ECRC20
     */
    function addNewAsset(bytes8 _symbol, address _contract_addr, uint _collateral_rate)
        external
        ownerOnly()
        returns(uint256 numberOfAssets)
    {
    require (_collateral_rate >0 && _collateral_rate < 1e4);
	int index = addressSearch(assetAddress, _contract_addr);
	if (index == -1) {
	    /* new asset */
	    assetAddress.push(_contract_addr);
	    assetName.push(_symbol);
	    ECRC20 newToken = ECRC20(_contract_addr);
	    asset.push(newToken);
	    collateralRates[_symbol] = _collateral_rate;
        } else {
	        /* asset exists, just update the symbol and rate */
	        assetName[uint(index)] = _symbol;
	        collateralRates[_symbol] = _collateral_rate;
        }
        return assetAddress.length;
    }

    /**
     * @notice add new pool, only contract owner
     * @param _name - the pool name
     * @param  _leader_addr - address of the depositor(pool leader)
     * @param  _EFG_amount - initial EFG amount for the pool
     * @return an uint256 , the current number of pools
     */
    function addNewPool(
        bytes8 _name,
        address _leader_addr,
        uint256 _EFG_amount
    ) external ownerOnly() returns(uint256 numberOfPools) {
	if(addressSearch(pool,_leader_addr) != -1) {
		return pool.length;
	    }
        pool.push(_leader_addr);
        Pool storage p = poolsData[_leader_addr];
        p.name = _name;
	p.capital = _EFG_amount;
        p.remainingEFG = _EFG_amount;
        return pool.length;
    }

    /**
     * @notice increase (deposit) EFG, pool founder only
     * @param  _EFG_amount - EFG amount to deposit
     * @return a boolean
     */
    function increaseCapital(uint256 _EFG_amount) external poolOwnerOnly() returns(bool result) {
	require(_EFG_amount > 0);
	/* send the tokens , it will fail if not appoved before */
        result = EFG.transferFrom(msg.sender, address(this), _EFG_amount);
        if (!result) {
            emit IncreaseCapitalEvent(false, msg.sender, _EFG_amount);
            return false;
        }
	Pool storage p = poolsData[msg.sender];
	p.capital += _EFG_amount;
	p.remainingEFG += _EFG_amount;
	emit IncreaseCapitalEvent(true, msg.sender, _EFG_amount);

	return true;
    }

    /**
     * @notice add or purge oracles, only contract owner
     * @param _oracleAddr - the address of the oracle to be add or remove
     * @param _action - a boolean , if true add to list; else unauthorize
     * @return a boolean , true on success
     */
    function authOracles(address _oracleAddr, bool _action)
        external
        ownerOnly()
        returns(bool result)
    {
        oracles[_oracleAddr] = _action;
        return true;
    }

    /**
     * @notice get exchange rate of asset/USDT , 6 decimal places
     * @param _symbol - asset's symbol
     * @return uint - the exchange rate between EFG and the asset
     */
    function getUSDTRate(bytes8 _symbol) external view returns(uint256 exchangeRate) {
        return USDTRates[_symbol];
    }

    /**
     * @notice set exchnage rate of asset/USDT, 6 decimal places, only authorized oracle
     * @param _symbol - asset's symbol
     * @param _rate - rate (asset/USDT)
     * @return bool
     */
    function setUSDTRate(bytes8 _symbol, uint256 _rate)
        external
        oracleOnly()
        returns(bool result)
    {
        require(_rate > 0);
        USDTRates[_symbol] = _rate;
        return true;
    }

    /**
     * @notice set the rates massively
     * @param _symbol - array of asset's symbols
     * @param _rate - aray of rates (asset/USDT)
     * @return bool
     */
    function setAllUsdtRates(bytes8[] _symbol, uint256[] _rate)
        external oracleOnly() returns(bool result) {
      for (uint i=0; i < _symbol.length; i++) {
	if(_rate[i]>0) {
	  USDTRates[_symbol[i]] = _rate[i];
	}
      }
       return true;
    }

    /**
     * @notice set interest rate , 4 decimal places, only contract owner
     * @param _interestRate - interest rate on EFG
     * @return bool
     */
    function setInterestRate(uint256 _interestRate)
        external
        ownerOnly()
        returns(bool result)
    {
        interestRateEFG = _interestRate;
        return true;
    }

    /**
     * @notice get interest rate, 4 decimal places
     * @return uint - the interest rate of EFG
     */
    function getInterestRate() external view returns(uint256 EFGInterestRate) {
        return interestRateEFG;
    }

    /**
     * @notice set collateral rate , 4 decimal places, only contract owner
     * @param _symbol - asset's symbol
     * @param _rate - borrow power of the asset
     * @return bool
     */
    function setCollateralRate(bytes8 _symbol, uint256 _rate)
        external
        ownerOnly()
        returns(bool result)
    {
        /* rate shoude be in range (0-100%) */
        require(_rate > 0);
        require(_rate < 10000);
        collateralRates[_symbol] = _rate;
        return true;
    }

    /**
     * @notice get collateral rate, 4 decimal places
     * @param _symbol -asset's symbol
     * @return uint256 - collateral rate (borrow limit) of the asset
     */
    function getCollateralRate(bytes8 _symbol) public view returns(uint256 collaterlRate) {
        return collateralRates[_symbol];
    }

    /* fallback not payable, don't accept ECOC deposits directly; throw the transaction */
    function() external {}

    /**
     * @notice Deposit ECOC
     * @param _pool_addr - pool address
     * @return bool
     */
    function depositECOC(address _pool_addr)
        external
        payable
        poolExists(_pool_addr)
        returns(bool result)
    {
        require(msg.value > 0);
        /* check if loan is locked */
        Loan storage l = debt[msg.sender];
        require(!l.locked);
	bool isNew = (l.poolAddr == address(0x0));
	/* forbid the deposit if an active loan already exists in another pool */
	require(isNew || (l.poolAddr == _pool_addr));

	Pool storage p = poolsData[_pool_addr];
        p.collateral[msg.sender]["ECOC"] += msg.value;
	
	if (isNew) {
	    usersPool[msg.sender] = _pool_addr;
	    int index = addressSearch(p.members, msg.sender);
	    if (index == -1) {
	        p.members.push(msg.sender);
	    }
	    /* Initialize the Loan */
	    l.poolAddr = _pool_addr;
	}
	/* check if it is first deposit of this asset */
	if(stringSearch(l.assetSymbol, "ECOC")==-1) {
	    l.assetSymbol.push("ECOC");
	    l.collateralRate.push(collateralRates["ECOC"]);
	}
	l.deposits["ECOC"] += msg.value;

        
        emit DepositECOCEvent(msg.sender, msg.value);
        return true;
    }
    
    /**
     * @notice Deposit ECRC20
     * @param _symbol - asset symbol
     * @param _amount - amount of ECRC tokens
     * @param _pool_addr - address of pool owner
     * @return bool
     */
    function depositAsset(bytes8 _symbol, uint256 _amount, address _pool_addr)
        external
        poolExists(_pool_addr)
        returns(bool result)
    {
        require(_amount > 0);
	Loan storage l = debt[msg.sender];
	if (_symbol=="GPT") {
	    require(l.poolAddr != address(0x0));
	    return depositGPT(_amount);
	}
        int index = stringSearch(assetName, _symbol);
        /* check if asset is acceptable */
        if (index == -1) {
                return false;
        }
        /* check if the loan is unlocked */
        require(!l.locked);
	bool isNew = (l.poolAddr == address(0x0));
	/* forbid the deposit if an active loan already exists in another pool */
	require(isNew || (l.poolAddr == _pool_addr));

	ECRC20 token = ECRC20(assetAddress[uint(index)]);

        /* send the tokens , it will fail if not appoved before */
        result = token.transferFrom(msg.sender, address(this), _amount);
        if (!result) {
            emit DepositAssetEvent(false, _symbol, msg.sender, _amount);
            return false;
        }

        usersPool[msg.sender] = _pool_addr;
        Pool storage p = poolsData[_pool_addr];
        p.collateral[msg.sender][_symbol] += _amount;

	if (isNew) {
	    usersPool[msg.sender] = _pool_addr;
	    index = addressSearch(p.members, msg.sender);
	    if (index == -1) {
	        p.members.push(msg.sender);
	    }
	    /* Initialize the Loan */
	    l.poolAddr = _pool_addr; 
	}
	/* check if this is the first deposit of this asset */
	if(stringSearch(l.assetSymbol, _symbol)==-1) {
	    l.assetSymbol.push(_symbol);
	    l.collateralRate.push(collateralRates[_symbol]);
	}
	l.deposits[_symbol] += _amount;
	
        emit DepositAssetEvent(true, _symbol, msg.sender, _amount);
        return true;
    }

     /**
     * @notice deposi GPT
     * @param _amount - amount of ECRC tokens
     * @return bool
     */
    function depositGPT(uint256 _amount) internal returns (bool result) {
	Loan storage l = debt[msg.sender];
        result = GPT.transferFrom(msg.sender, address(this), _amount);
        if (!result) {
            emit DepositAssetEvent(false, "GPT", msg.sender, _amount);
            return false;
        }
	emit DepositAssetEvent(true, "GPT", msg.sender, _amount);
	l.remainingGPT += _amount;
	return true;
    }

    /**
     * @notice boorow EFG
     * @param _amount - amount to borrow in EFG
     * @return uint256 - total borrowed EFG
     */
    function borrow(uint256 _amount) external returns(uint256 borrowedEFG) {
        address poolAddr = usersPool[msg.sender];
	    /* necessary checks */
	    require(!(addressSearch(pool, poolAddr) == -1 ));
	    require(_amount < computeBorrowingPower(msg.sender));
        Pool storage p = poolsData[poolAddr];
	    require(_amount <= p.remainingEFG);
        
        Loan storage l = debt[msg.sender];
        bool firstBorrow = !(l.locked);
	
        /* create or update loan info */
        if (firstBorrow) {
	    l.locked = true;
            l.xrate = USDTRates["EFG"];
            l.interestRate = interestRateEFG;
            l.poolAddr = poolAddr;
        } else {
	    /* update interest*/
            l.interest +=
                (l.EFGamount * sub(block.timestamp, l.timestamp) * l.interestRate) /
                (secsInDay * 1e4);
        }
        l.timestamp = block.timestamp;
        l.EFGamount += _amount;
        p.remainingEFG = sub(p.remainingEFG, _amount);
	
        emit BorrowEvent(firstBorrow, poolAddr, msg.sender, _amount);

	/* also withdraw that amount */
        require(EFG.transfer(msg.sender, _amount));
        emit WithdrawEFGEvent(msg.sender, _amount);

        return _amount;
    }
    
    /**
     * @notice get EFG amount of debt
     * @param _debtor - debtor's address
     * @return uint - the total debt in EFG
     * @return address - the pool where the loan exists
     */
    function getDebt(address _debtor) public view returns(uint256 totalDebt, address poolAddress) {
        Loan memory d = debt[_debtor];
        totalDebt = d.EFGamount + d.interest;
        uint256 lastInterest = ((d.EFGamount *
            (sub(block.timestamp, d.timestamp) * d.interestRate)) /
            (secsInDay * 1e4));
        totalDebt += lastInterest;
        return (totalDebt, d.poolAddr);
    }

    /**
     * @notice fully or partially repay ECOC
     * @param _amount of EFG to be payed back
     * @return bool
     */
    function repay(uint256 _amount) external returns (bool result) {
        require(_amount > 0);
	require(d.EFGamount !=0);
	Loan storage d = debt[msg.sender];
	uint256 maxEFG = d.EFGamount + d.interest + (d.EFGamount * ((block.timestamp - d.timestamp)
			* d.interestRate)) / (secsInDay * 1e4);
	uint256 amount;
	if (_amount > maxEFG) {
	    amount = maxEFG;
	} else {
	    amount = _amount;
	}

	/* send EFG first , it will fail if not appoved before */
        result = EFG.transferFrom(msg.sender, address(this), amount);
        if (!result) {
            emit DepositAssetEvent(false, "EFG", msg.sender, amount);
            return false;
        }

	/* update interest first */
            d.interest += (d.EFGamount * (sub(block.timestamp, d.timestamp)
			   * d.interestRate)) / (secsInDay * 1e4);
	    d.timestamp = block.timestamp;
        if (amount <= d.interest) {
            /* repay the interest first */
            d.interest = sub(d.interest, amount);
	    totalInterestAmount += amount;
	    EFGBalance[d.poolAddr] += amount;
            emit RepayEvent(false , msg.sender, amount);
            return true;
        }

        /* repay amount is greater than interest, decrease the loan */
	Pool storage p = poolsData[d.poolAddr];
        uint256 amountLeft = sub(amount, d.interest);
	EFGBalance[d.poolAddr] += d.interest;
	totalInterestAmount += d.interest;
        d.interest = 0;
        if (d.EFGamount > amountLeft) {
              d.EFGamount = sub(d.EFGamount, amountLeft);
	      p.remainingEFG += amountLeft;
              emit RepayEvent(false , msg.sender, amount);
              return true;
        } else {
            /* loan repayed in full, release the collateral and GPT */
	    p.remainingEFG += d.EFGamount;
	    d.EFGamount = 0;
	    balance[msg.sender]["GPT"] += d.remainingGPT;
	    d.remainingGPT = 0;
	    emit RepayEvent(true , msg.sender, amount);
	    
	    /* reset and unlock the loan */
	    d.locked = false;
	    d.protectionUsed = false;
	    d.timestamp = 0;
	    d.interestRate = 0;
	    d.xrate = 0;
	    d.lastGracePeriod = 0;
	    d.collateralRate.length = 0;
	    /* Repopulate the collateralRate array*/
	    for(uint index=0; index<d.assetSymbol.length; index++) {
		d.collateralRate.push(collateralRates[d.assetSymbol[index]]);
	    }

            return true;
        }
    }

    /**
     * @notice withdraw ECOC
     * @param _amount of ECOC to be withdrawn
     * @param _beneficiars_addr - withdrawal address
     * @return bool
     */
    function withdrawECOC(uint256 _amount, address _beneficiars_addr)
        external
        payable
        returns(bool result)
    {
        require(_amount > 0);
	Loan storage l = debt[msg.sender];
        int index = stringSearch(l.assetSymbol, "ECOC");
        if (!l.locked && (index != -1)) {
	    /* the caller is a common user */
	    require(_amount <= l.deposits["ECOC"]);
	    l.deposits["ECOC"] = sub(l.deposits["ECOC"], _amount);
            Pool storage p = poolsData[l.poolAddr];
            p.collateral[msg.sender]["ECOC"] = sub(p.collateral[msg.sender]["ECOC"], _amount);
            /* if all collateral were withdrawn then delete the loan */
            if (computeCollateralValue(msg.sender) == 0) {
                deleteLoan(msg.sender);
            }
        } else {
	    /* for owner and pool leaders */
	    require(_amount <= balance[msg.sender]["ECOC"]);
	    balance[msg.sender]["ECOC"] = sub(balance[msg.sender]["ECOC"], _amount);
	}
	if (msg.sender == owner) {
	    /* transfer throws on failure */
	    ownerWallet.transfer(_amount);
	    emit WithdrawECOCEvent(msg.sender, ownerWallet, _amount);
	} else {
	    /* transfer throws on failure */
	    _beneficiars_addr.transfer(_amount);
	    emit WithdrawECOCEvent(msg.sender, _beneficiars_addr, _amount);
	}
        return true;
    }

    /**
     * @notice withdraw Asset (ECRC20)
     * @param _symbol - asset symbol
     * @param _amount - amount of asset to be withdrawn
     * @param _beneficiars_addr - withdraw to this address
     * @return bool
     */
    function withdrawAsset(bytes8 _symbol, uint256 _amount, address _beneficiars_addr) external returns(bool result) {
        require(_amount > 0);
	Loan storage l = debt[msg.sender];
	if (_symbol == "GPT") {
	    if(msg.sender == owner) {
		return withdrawGPT(_amount);
		} else {
		/* common user */
		require(l.remainingGPT + balance[msg.sender]["GPT"] >= _amount);
		if(_amount > balance[msg.sender]["GPT"]){
		  uint256 diff = sub(_amount, balance[msg.sender]["GPT"]);
		    balance[msg.sender]["GPT"] += diff;
		    l.remainingGPT = sub(l.remainingGPT, diff);
		}
	       require(GPT.transfer(_beneficiars_addr, _amount));
	       balance[msg.sender]["GPT"] = sub(balance[msg.sender]["GPT"], _amount);
	       emit WithdrawAssetEvent(true, _beneficiars_addr, _symbol, _amount);
	       return true;
	   }
	}
	if (_symbol != "EFG") {
	    int index = stringSearch(l.assetSymbol, _symbol);
	    if (!l.locked && (index != -1) && (_symbol != "GPT")) {
		/* the caller is a common user */
		require(_amount <= l.deposits[_symbol]);
		l.deposits[_symbol] = sub(l.deposits[_symbol], _amount);
		Pool storage p = poolsData[l.poolAddr];
		p.collateral[msg.sender][_symbol] = sub(p.collateral[msg.sender][_symbol], _amount);
		/* if all collateral were withdrawn then delete the loan */
		if (computeCollateralValue(msg.sender) == 0) {
		    deleteLoan(msg.sender);
		}
	    }  else {
		/* for owner and pool leaders */
		require(_amount <= balance[msg.sender][_symbol]);
		balance[msg.sender][_symbol] = sub(balance[msg.sender][_symbol], _amount);
	    }
	
	    /* send the tokens */
		index =  stringSearch(assetName, _symbol);
		assert(index != -1); /* should never happen */
		if(msg.sender == owner) {
		    require(asset[uint(index)].transfer(ownerWallet, _amount));
		    emit WithdrawAssetEvent(true, ownerWallet, _symbol, _amount);
		} else {
		    require(asset[uint(index)].transfer(_beneficiars_addr, _amount));
		    emit WithdrawAssetEvent(true, _beneficiars_addr, _symbol, _amount);
	    }	    
	    return true;
	} else {
	    /* send the EFG */
	    return withdrawEFG(_amount, _beneficiars_addr);
	}
    }

    /**
     * @notice withdraw EFG
     * @param _amount - EFG amount
     * @param _beneficiars_addr - withdraw to this address
     * @return bool
     */
    function withdrawEFG(uint256 _amount, address _beneficiars_addr) internal returns(bool result) {
        require(EFGBalance[msg.sender] >= _amount);
        EFGBalance[msg.sender] = sub(EFGBalance[msg.sender], _amount);
        /* send the tokens */
	if(msg.sender == owner){
	    require(EFG.transfer(ownerWallet, _amount));
	    emit WithdrawEFGEvent(ownerWallet, _amount);
	} else {
	    require(EFG.transfer(_beneficiars_addr, _amount));
	    emit WithdrawEFGEvent( _beneficiars_addr, _amount);
	}
        return true;
    }

    /**
     * @notice margin call, only by pool owner and only on the condition that collateral has fallen short
     * @param _debtors_addr - address of debtor
     * @return bool
     */
    function marginCall(address _debtors_addr)
        external
        returns(bool result)
    {
	require(canSeize(_debtors_addr));
	/* auto trigger grace period if possible */
	if(extendGracePeriod(_debtors_addr)) {
	  return false;
	}
        Loan storage l = debt[_debtors_addr];
	/* check if the caller is the pool leader or the contract owner */
        require((msg.sender == l.poolAddr) || (msg.sender == owner));

	/* seize the collateral */
        Pool storage p = poolsData[l.poolAddr];
	
	for (uint i=0; i < l.assetSymbol.length; i++ ) {
	  balance[l.poolAddr][l.assetSymbol[i]] += l.collateralRate[i]* p.collateral[_debtors_addr][l.assetSymbol[i]] / 1e4
	    + (sub(1e4, l.collateralRate[i])* p.collateral[_debtors_addr][l.assetSymbol[i]] / 1e4) / 2 ; /* 50% profit*/
	  balance[owner][l.assetSymbol[i]] +=  (sub(1e4, l.collateralRate[i])* p.collateral[_debtors_addr][l.assetSymbol[i]] / 1e4) / 2; /* 50% profit*/
	  /* also, remove the asssets from the pool */
	  p.collateral[_debtors_addr][l.assetSymbol[i]] = 0;
	  l.deposits[l.assetSymbol[i]] = 0;
	}
    
    emit  MarginCallEvent(l.poolAddr, _debtors_addr);
    totalLiqudatedEFGEq += l.EFGamount;
    deleteLoan(_debtors_addr);
    
    return true;
    }

    /**
     * @notice extend Grace Period if possible
     * @param _debtors_addr - debtor's address
     * @return bool - true on success, else false
     */
    function extendGracePeriod(address _debtors_addr) internal returns(bool result) {
        /* check if debt exists*/
        Loan storage l = debt[_debtors_addr];
	/* each loan has right for a single grace period only */
	if (l.protectionUsed == true) {
	    return false;
	}
	
        /* check if GPT is enough to activate the grace period */
	uint256 protectedValue = computeCollateralValue(_debtors_addr);
	uint256 totalDebt;
	(totalDebt,) = getDebt(_debtors_addr);
	/* in case of non triggered margin call */
	if (protectedValue < totalDebt) {
	    protectedValue = totalDebt;
	}
	
	if (l.remainingGPT == 0) {
	    return false;
	}
	uint256 GPTRate = computeEFGRate(USDTRates["GPT"], USDTRates["EFG"]);
        if (protectedValue * periodRate / 1e2 > l.remainingGPT *1e4 * GPTRate / 1e6){
	    return false;
	}

	/* trigger the protection and update loan data*/
        uint256 consumedGPT = (protectedValue * periodRate * 1e4) / GPTRate; /* 1e6 * 1e-2 */
	consumedGPT /= 1e4; /* convert from 8 decimals to 4 */
	/* set the minimum if the precision is not enough */
	if(consumedGPT == 0 ) {
	    consumedGPT = 1; /* minimum GPT that can exist, 1e-4*/
	}
	if (l.remainingGPT < consumedGPT) { /* reduntant check */
	    return false;
	}
    
    l.protectionUsed = true;	
	l.remainingGPT = sub(l.remainingGPT, consumedGPT);
	l.lastGracePeriod = block.timestamp + secsIn7Hours;

	balance[owner]["GPT"] += consumedGPT;
	totalConsumedGPT += consumedGPT;
        emit ExtendGracePeriodEvent(_debtors_addr, consumedGPT);

       return true;
    }

    /**
     * @notice withdraw GPT , owner only
     * @param _amount - amount of GPT to withdrawn. If it is set to zero then  withdraw the total
     * @return bool - true on success, else false
     */
    function withdrawGPT(uint256 _amount) public ownerOnly() returns(bool result){
        require(balance[owner]["GPT"] > 0);
        uint256 requestedAmount = _amount;
        if ((_amount == 0) || ((_amount > balance[owner]["GPT"]))) {
            requestedAmount = balance[owner]["GPT"];
        }

        /* send the GPT tokens */
	result = GPT.transfer(ownerWallet, requestedAmount);
        if(!result) {
            emit WithdrawGPTEvent(false, msg.sender, requestedAmount);
            return false;
        } else {
            emit WithdrawGPTEvent(true, msg.sender, requestedAmount);
	    balance[owner]["GPT"] = sub(balance[owner]["GPT"], requestedAmount);
            return true;
        }
    }

    /**
     * @notice display asset balance
     * @param _symbol asset
     * @param _address beneficiar's address
     * @return uint256
     */
    function getAssetBalance(bytes8 _symbol, address _address)
        external
        view
        returns(uint256 assetBalance)
    {
	if (_symbol == "GPT") {
	    Loan memory l = debt[_address];
	    return (l.remainingGPT + balance[_address]["GPT"]);
	}
	if (_symbol != "EFG") {
	    return balance[_address][_symbol];
	} else {
	    return EFGBalance[_address];
	}
    }

    /*
     * @notice get all founder's pools
     * @return address[] - array of all pool addresses
     */
    function getAllPools() public view returns (address[] allPools) {
        return pool;
    }

    /**
     * @notice list all active pool members
     * @param _pool_addr - pool address
     * @return address[] - array of all members in the pool
     */
    function listPoolUsers(address _pool_addr) external view poolExists(_pool_addr) returns(address[] members) {
        Pool storage p = poolsData[_pool_addr];
        return p.members;
    }

    /**
     * @notice list all liquidable loans for a pool
     * @param _pool_addr - pool address
     * @param _start  - start searching of this index in member's pool
     * @param _offset - how many members to search. If 0, then search the whole members of the pool
     * @return address[] - array of all members in the pooladdresses of debtors that fallen short
     */
    function listLiquidable(address _pool_addr, uint _start, uint _offset) external view poolExists(_pool_addr)
	returns(address[] liquidable){
	    Pool storage p = poolsData[_pool_addr];
	    uint start = _start;
	    uint offset = _offset;
	    if (_offset == 0) {
		offset = p.members.length;
	    }

	    uint length = start + offset;
	    if (length > p.members.length) {
		length = p.members.length;
	    }
	    address[] memory fallenShort = new address[](length);
	    for (uint i=start; i < length  ; i++) {
	        if (canSeize(p.members[i])) {
		  fallenShort[i] = p.members[i];
		}
	    }
	    return fallenShort;
    }

    /**
     * @notice returns loan's information
     * @param _debtor_addr - debtor
     * @return uint256 - EFG amount
     * @return uint256 - last timestamp of loan creation or update
     * @return uint256 - last interast rate in EFG
     * @return uint256 - total interest
     * @return uint256 - initial rate of EFG/USDT
     * @return uint256 - timestamp of ending grace period
     * @return uint256 - remainingGPT
     * @return uint256 - remainingGPT
     * @return address - founder's address
     */
    function getLoanInfo(address _debtor_addr)
        external
        view
        returns (
            uint256 amount,
            uint256 timestamp,
            uint256 interestRate,
            uint256 interest,
	    uint256 EFGInitialRate,
	    uint256 lastGracePeriod,
	    uint256 remainingGPT,
	    bool gracePeriodUsed,
            address poolAddr
        )
    {
        Loan memory l = debt[_debtor_addr];
        return (l.EFGamount, l.timestamp, l.interestRate, l.interest,
		l.xrate, l.lastGracePeriod, l.remainingGPT, l.protectionUsed, l.poolAddr);
    }

    /**
     * @notice returns pool's information
     * @param _pool_addr - founder's address
     * @return bytes8 - pool name
     * @return uint256 - capital
     * @return uint256 - remaining EFG
     */
    function getPoolInfo(address _pool_addr)
        external
        view
        returns (
            bytes32 name,
            uint256 capital,
	    uint256 remainingEFG
        )
    {
        Pool memory p = poolsData[_pool_addr];
        return (p.name, p.capital, p.remainingEFG);
    }

    /**
     * @notice returns type and amount of locked assets
     * @param _debtors_addr - debtor's address
     * @return bytes8 - array of symbols
     */
    function getCollateralSymbols(address _debtors_addr) external view returns(bytes8[] collateralSymbol) {
        Loan storage l = debt[_debtors_addr];
	return l.assetSymbol;
    }

    /**
     * @notice returns type and amount of locked assets
     * @param _debtors_addr - debtor's address
     * @return uint256[] - dynamic array of amount of each collateral type , 8 decimals , 100 elements limit
     */
    function getCollateralAmount(address _debtors_addr) external view returns(uint256[] collateralAmount) {
        Loan storage l = debt[_debtors_addr];
    uint256[] memory amounts = new uint256[](l.assetSymbol.length);
	for(uint i = 0; i < l.assetSymbol.length ; i++) {
	  amounts[i] = l.deposits[l.assetSymbol[i]];
	}
	return amounts;
    }
    /**
     * @notice returns estimated GPT to be used as delay for 7 hours
     * @param _debtors_addr - debtor's address
     * @return uint256 - GPT needed , 4 decimal place
     */
     function getEstimatedGPT(address _debtors_addr) external view returns(uint256 GPTamount) {
         Loan memory l = debt[_debtors_addr];
         if (l.EFGamount == 0) {
            return 0;
        }

        uint256 GPTRate = computeEFGRate(USDTRates["EFG"], USDTRates["GPT"]);
	uint256 protectedValue = computeCollateralValue(_debtors_addr);
	/* check if there is no margin call on time */
	uint256 totalDebt;
	(totalDebt,) = getDebt(_debtors_addr);
	if (protectedValue < totalDebt) {
	    protectedValue = totalDebt;
	}
	GPTamount = (protectedValue * periodRate * GPTRate) / 1e12; /* 1e-6*1e-2*(1e4*1e-8) */
    if (l.remainingGPT > GPTamount ) {
            return 0;
        }
	GPTamount = sub(GPTamount, l.remainingGPT);
        return GPTamount;
     }

    /**
     * @notice returns the pool address
     * @param _depositors_addr - debtor's address
     * @return uint256 - pools address or the zero address if no collateral exists
     */
    function getUserPool(address _depositors_addr) external view returns(address) {
	require(usersPool[_depositors_addr] != address(0x0));
        return usersPool[_depositors_addr];
    }

    /**
     * @notice returns the addresses of all ECRC20 assets that are acceptable by the system
     * @return address[]
     */
    function getAllAssets() external view returns(address[] allAcceptedAssets) {
        return assetAddress;
    }
     /**
     * @notice computes asset/EFG rate
     * @param _assetRate - asset/USDT
     * @param _EFGRate - EFG/USDT
     * @return uint256 - amount of the collateral , 6 decimals
     */
    function computeEFGRate(uint256 _assetRate, uint256 _EFGRate) internal pure returns(uint256) {
        uint256 assetToEFG;
        require((_EFGRate > 0) && (_assetRate > 0));

        assetToEFG = (_assetRate * 1e6 )/ _EFGRate; /* 6 decimal places */
        return assetToEFG;
    }

    /**
     * @notice compute total collateral value in USDT
     * @param _depositors_addr - address of the depositor
     * @return uint - total collateral value in EFG , 8 digits
     */
    function computeCollateralValue(address _depositors_addr) internal view returns (uint value) {
       Loan storage l = debt[_depositors_addr];

       uint256 totalValue = 0;
       for(uint256 i = 0 ; i < l.assetSymbol.length; ++i ) {
           totalValue += l.deposits[l.assetSymbol[i]] * l.collateralRate[i]
	     * computeEFGRate(USDTRates[l.assetSymbol[i]], USDTRates["EFG"]);
       }
       totalValue /= 1e10 ; /* usdt rate 1e6, collateral rate 1e4 */

       return totalValue;
    }

    /**
     * @notice compute borrowing power
     * @param _depositors_addr - address of the depositor
     * @return uint - borrowing power (left to lend) in EFG , 8 digits
     */
    function computeBorrowingPower(address _depositors_addr) internal view returns (uint lendableEFG) {
	/* get the total debt */
	uint256 totalDebt;
	(totalDebt,) = getDebt(_depositors_addr);
	/* compute the maximum borrowing power in EFG */
	uint256 maxBorrowing;
	maxBorrowing = computeCollateralValue(_depositors_addr);
	/* compute the difference*/
	if (maxBorrowing <= totalDebt) {
	    return 0;
	}
        return sub(maxBorrowing, totalDebt);
    }

    /**
     * @notice compute borrowing limit , same as computeCollateralValue()
     * @param _depositors_addr - address of the depositor
     * @return uint - borrowing limit (left to lend) in EFG , 8 digits
     */
    function getBorrowLimit(address _depositors_addr) external view returns(uint lendable) {
        return computeCollateralValue(_depositors_addr);
    }

    /**
     * @notice search element in array
     * @param _targetArray - array to be searched
     * @param _element - what to search
     * @return int - array index if elemnt exists, else -1
     */
    function addressSearch(address[] _targetArray, address _element) internal pure returns (int index) {
        index = -1;
        for (uint i = 0; i < _targetArray.length; i++) {
            if (_targetArray[i] == _element) {
                index = int(i);
                break;
            }
        }
        return index;
    }

    /**
     * @notice  returns total interest for leaders, for information purposes only
     * @return uint - total consumed GPT so farinterest in EFG
     */
    function getTotalInterest() external view returns(uint totalInterest) {
	return totalInterestAmount;
    }

    /**
     * @notice  returns total unpaid EFG, for information purposes only
     * @return uint - total unpaid EFG because of liquidation
     */
    function getTotalLiquidated() external view returns(uint totalLiquidated) {
	return totalLiqudatedEFGEq;
    }

    /**
     * @notice returns total used GPT, for information purposes only
     * @return uint - total consumed GPT so far
     */
    function getTotalConsumedGPT() external view returns(uint totalGPT) {
	return totalConsumedGPT;
    }
    
    /**
     * @notice search element in array
     * @param _targetArray - array to be searched
     * @param _element - what to search
     * @return int - array index if elemnt exists, else -1
     */
    function stringSearch(bytes8[] _targetArray, bytes8 _element) internal pure returns (int index) {
        index = -1;
        for (uint i = 0; i < _targetArray.length; i++) {
            if (_targetArray[i] == _element) {
                index = int(i);
                break;
            }
        }
        return index;
    }

    function deleteLoan(address _debtors_addr) internal returns (bool) {
	Loan storage l = debt[_debtors_addr];
	Pool storage p = poolsData[l.poolAddr];
	/* return GPT to the user */
	balance[_debtors_addr]["GPT"] += l.remainingGPT;

	delete debt[_debtors_addr];
	delete usersPool[_debtors_addr];

	int memberIndex = addressSearch(p.members, _debtors_addr);
	/* swap with last element and remove */
	uint length = p.members.length;
	if(length>0) {
	    p.members[uint(memberIndex)] = p.members[length-1];
	    delete p.members[length-1];
	    p.members.length--;
	}

	return true;
    }

    /**
     * @notice safe sub of uints, throws on underflow
     * @param _a - 
     * @param _b - 
     * @return uint256 - result of subtraction
     */
    function sub(uint256 _a, uint256 _b) internal pure returns (uint256) {
        assert(_b <= _a);
        uint256 c = _a - _b;

        return c;
    }
}
