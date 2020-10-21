# EFG

## Deployemnt
- Deploy EFG
- Deploy GPT
- Deploy staking contracts (pass EFG and GPT smart contract addresses to constructor)
- Deploy lending contracts (pass EFG and GPT smart contract addresses to constructor)
- GPT owner manualy transfers the total GPT amount to the staking contract address
- Leaders acuire(buy) EFG tokens from the contract owner

## Pool initialization:
EFG is transfered manually to the lending smart contract
Lending contract owner of lending contract triggers addNewPool(), setting the name, leader address and the amount of EFG for the pool
Repeat the above for each leader

## Nececssary actions
Lending contract owner activates oracles using the authorizeOracle() function
Lending contract owner adds ECRC20 tokens that can be accepted as collatrals (this can be done later, no need to be done in the initial phase)

## For GPT staking
Anyone can stake GPT if he owns EFG. The process is the following
- He triggers approve() function of EFG allowing the EFG amount he wants to use for staking. The spender address is the staking smart contract address.
- Then he triggers the mintGPT() function of staking contract
- As the time passes the user can withdraw GPT any time, as long as there is GPT inside the contract. He can check his EFG and GPT balance by calling mintingInfo(). He can also check the total remaining GPT of the contract calling unclaimedGPT()
- User can withdraw EFG at any time via the withdrawEFG() function. To withdraw GPT he must use the claimStakedGPT() function
- EFG and GPT can be withdrawn to a different address of the deposited address
- claimStakedGPT returns all GPT to the beneficiar. If the amount is more than the remaining GPT in the smart contract then the withdraw is still valid. The user receives the remaining GPT of the smart contract.

## Lending contract

-Oracles update fequently the rates of all assets (ECOC,new assets,EFG and GPT)
- new pools and new assets can be added anytime by contract owner. Before creating a new pool the equivalent EFG amount must be transfered manually to the lending smart contract
- smart contract and pool owners are not treated differently for the functions withdrawAsset(), withdrawEcoc(),withdrawEFG(). After succesully seizing the collateral or after loan repaying they can withdraw normally the assets (including EFG and GPT) to their accounts.
- Users can partially repay the loan via repay() function. For the collateral to be release they must fully repay.
- More GPT can be deposited at any time. User must approve() first the GPT to the lending smart contract address. extendGracePeriod() consumes 5% of the total cuurent debt of the user and blocks liquidation for seven hours. any remaing GPT stays inside , so it can be used for the next extending if the user uses. User cant withdraw the remaing GPT though.

