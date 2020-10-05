require("dotenv").config({ path: "../.env" });

const { Ecocw3 } = require("ecoweb3");
const ECOC = {
  ADDR: process.env.ADDR,
  PRIV_KEY: process.env.PRIV_KEY,
  ENDPOINT: process.env.ENDPOINT,
  NET: process.env.CHAIN_MODE,
  CONTRACT_ADDR: process.env.LENDING_SMARTCONTRACT_ADDR
};

config = {
  rpcProvider: ECOC.ENDPOINT,
  networkStr: ECOC.NET
};

const ecocw3 = new Ecocw3(config);
const rpc = Ecocw3.Rpc(ECOC.ENDPOINT);

const contract_abi =[
	{
		"constant": false,
		"inputs": [
			{
				"name": "_symbol",
				"type": "string"
			},
			{
				"name": "_rate",
				"type": "uint256"
			}
		],
		"name": "setEFGRate",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_lock",
				"type": "uint256"
			}
		],
		"name": "depositECOC",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": true,
		"stateMutability": "payable",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_amount",
				"type": "uint256"
			}
		],
		"name": "withdrawEFG",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_rate",
				"type": "uint256"
			}
		],
		"name": "setCollateralRate",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_symbol",
				"type": "string"
			},
			{
				"name": "_interestRate",
				"type": "uint256"
			}
		],
		"name": "setInterestRate",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [],
		"name": "getCollateralRate",
		"outputs": [
			{
				"name": "",
				"type": "uint256"
			}
		],
		"payable": false,
		"stateMutability": "view",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_amount",
				"type": "uint256"
			}
		],
		"name": "lockECOC",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [
			{
				"name": "_symbol",
				"type": "string"
			}
		],
		"name": "getInterestRate",
		"outputs": [
			{
				"name": "",
				"type": "uint256"
			}
		],
		"payable": false,
		"stateMutability": "view",
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [
			{
				"name": "_debtor",
				"type": "address"
			}
		],
		"name": "getDebt",
		"outputs": [
			{
				"name": "",
				"type": "uint256"
			}
		],
		"payable": false,
		"stateMutability": "view",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "amount",
				"type": "uint256"
			}
		],
		"name": "payback",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_amount",
				"type": "uint256"
			},
			{
				"name": "_beneficiaries_addr",
				"type": "address"
			}
		],
		"name": "withdrawEcoc",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": true,
		"stateMutability": "payable",
		"type": "function"
	},
	{
		"constant": true,
		"inputs": [
			{
				"name": "_symbol",
				"type": "string"
			}
		],
		"name": "getEFGRates",
		"outputs": [
			{
				"name": "",
				"type": "uint256"
			}
		],
		"payable": false,
		"stateMutability": "view",
		"type": "function"
	},
	{
		"constant": false,
		"inputs": [
			{
				"name": "_oracleAddr",
				"type": "address"
			},
			{
				"name": "_action",
				"type": "bool"
			}
		],
		"name": "authOracles",
		"outputs": [
			{
				"name": "",
				"type": "bool"
			}
		],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [],
		"payable": false,
		"stateMutability": "nonpayable",
		"type": "constructor"
	}
];

const contract = ecocw3.Contract(ECOC.CONTRACT_ADDR, contract_abi);


module.exports = {
    
};
