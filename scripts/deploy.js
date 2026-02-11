import hre from "hardhat";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", hre.ethers.formatEther(balance), "ETH");

  if (balance === 0n) {
    console.error("No ETH! Get testnet ETH from https://faucet.testnet.chain.robinhood.com/");
    process.exit(1);
  }

  // Deploy with 5 minute withdrawal delay (300 seconds)
  const withdrawalDelay = 300;
  console.log(`\nDeploying StockPortfolioVault (withdrawal delay: ${withdrawalDelay}s)...`);

  const Vault = await hre.ethers.getContractFactory("StockPortfolioVault");
  const vault = await Vault.deploy(withdrawalDelay);
  await vault.waitForDeployment();

  const address = await vault.getAddress();
  console.log("\nStockPortfolioVault deployed to:", address);
  console.log("Explorer:", `https://explorer.testnet.chain.robinhood.com/address/${address}`);
  console.log("\nOwner:", deployer.address);
  console.log("Withdrawal delay:", withdrawalDelay, "seconds");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
