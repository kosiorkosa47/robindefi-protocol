import hre from "hardhat";

const VAULT_ADDRESS = "0x45b6f99e5A32e6a2457113D3DCCDAb07e157C13c";

async function main() {
  const [signer] = await hre.ethers.getSigners();
  const vault = await hre.ethers.getContractAt("StockPortfolioVault", VAULT_ADDRESS, signer);

  console.log("=== StockPortfolioVault Interaction ===\n");
  console.log("Vault:", VAULT_ADDRESS);
  console.log("Signer:", signer.address);

  const balance = await hre.ethers.provider.getBalance(signer.address);
  console.log("Wallet ETH:", hre.ethers.formatEther(balance));

  // ── 1. Deposit ETH ───────────────────────────────────────────────
  const depositAmount = hre.ethers.parseEther("0.005");
  console.log("\n--- Depositing 0.005 ETH ---");
  const tx1 = await vault.depositETH({ value: depositAmount });
  console.log("TX:", tx1.hash);
  await tx1.wait();
  console.log("Deposit confirmed!");

  // ── 2. Check portfolio ────────────────────────────────────────────
  const portfolio = await vault.getPortfolio(signer.address);
  console.log("\n--- Portfolio ---");
  console.log("ETH balance in vault:", hre.ethers.formatEther(portfolio.ethBalance));
  console.log("Total deposits:", portfolio.totalDeposits.toString());
  console.log("Time until unlock:", portfolio.timeUntilUnlock.toString(), "seconds");

  // ── 3. Check vault stats ──────────────────────────────────────────
  const totalUsers = await vault.totalUsers();
  const owner = await vault.owner();
  const delay = await vault.withdrawalDelay();
  const paused = await vault.paused();
  console.log("\n--- Vault Stats ---");
  console.log("Total users:", totalUsers.toString());
  console.log("Owner:", owner);
  console.log("Withdrawal delay:", delay.toString(), "seconds");
  console.log("Paused:", paused);

  // ── 4. Second deposit ─────────────────────────────────────────────
  console.log("\n--- Depositing another 0.003 ETH ---");
  const tx2 = await vault.depositETH({ value: hre.ethers.parseEther("0.003") });
  console.log("TX:", tx2.hash);
  await tx2.wait();
  console.log("Second deposit confirmed!");

  // ── 5. Updated portfolio ──────────────────────────────────────────
  const portfolio2 = await vault.getPortfolio(signer.address);
  console.log("\n--- Updated Portfolio ---");
  console.log("ETH balance in vault:", hre.ethers.formatEther(portfolio2.ethBalance));
  console.log("Total deposits:", portfolio2.totalDeposits.toString());
  console.log("Time until unlock:", portfolio2.timeUntilUnlock.toString(), "seconds");

  // ── 6. Vault ETH balance ──────────────────────────────────────────
  const vaultBalance = await hre.ethers.provider.getBalance(VAULT_ADDRESS);
  console.log("\n--- Vault Total ---");
  console.log("Total ETH locked in vault:", hre.ethers.formatEther(vaultBalance));

  const walletAfter = await hre.ethers.provider.getBalance(signer.address);
  console.log("Wallet ETH remaining:", hre.ethers.formatEther(walletAfter));

  console.log("\n=== Done! Check explorer: ===");
  console.log(`https://explorer.testnet.chain.robinhood.com/address/${VAULT_ADDRESS}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
