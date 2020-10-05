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

const contract_abi =[];

const contract = ecocw3.Contract(ECOC.CONTRACT_ADDR, contract_abi);


module.exports = {
    
};
