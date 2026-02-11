import hre from "hardhat";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("=== RobinDeFi Protocol Deployment ===\n");
  console.log("Deployer:", deployer.address);
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Balance:", hre.ethers.formatEther(balance), "ETH\n");

  // ── 1. Mock Stock Tokens ──────────────────────────────────────────
  console.log("--- Deploying Mock Stock Tokens ---");
  const MockToken = await hre.ethers.getContractFactory("MockStockToken");

  const tsla = await MockToken.deploy("Tesla Stock Token", "TSLA", 18);
  await tsla.waitForDeployment();
  console.log("TSLA:", await tsla.getAddress());

  const amzn = await MockToken.deploy("Amazon Stock Token", "AMZN", 18);
  await amzn.waitForDeployment();
  console.log("AMZN:", await amzn.getAddress());

  const pltr = await MockToken.deploy("Palantir Stock Token", "PLTR", 18);
  await pltr.waitForDeployment();
  console.log("PLTR:", await pltr.getAddress());

  // ── 2. Price Oracle ───────────────────────────────────────────────
  console.log("\n--- Deploying Price Oracle ---");
  const Oracle = await hre.ethers.getContractFactory("SimplePriceOracle");
  const oracle = await Oracle.deploy();
  await oracle.waitForDeployment();
  console.log("Oracle:", await oracle.getAddress());

  // Set prices (ETH per 1 token, 18 decimals)
  // TSLA ~$350 = ~0.1 ETH, AMZN ~$220 = ~0.065 ETH, PLTR ~$120 = ~0.035 ETH
  const tslaAddr = await tsla.getAddress();
  const amznAddr = await amzn.getAddress();
  const pltrAddr = await pltr.getAddress();

  const tx = await oracle.setBatchPrices(
    [tslaAddr, amznAddr, pltrAddr],
    [
      hre.ethers.parseEther("0.1"),    // TSLA = 0.1 ETH
      hre.ethers.parseEther("0.065"),  // AMZN = 0.065 ETH
      hre.ethers.parseEther("0.035"),  // PLTR = 0.035 ETH
    ]
  );
  await tx.wait();
  console.log("Prices set: TSLA=0.1 ETH, AMZN=0.065 ETH, PLTR=0.035 ETH");

  // ── 3. RH Index Fund ─────────────────────────────────────────────
  console.log("\n--- Deploying RH Index Fund (rhTECH) ---");
  const IndexFund = await hre.ethers.getContractFactory("RHIndexFund");
  const indexFund = await IndexFund.deploy(
    "RH Tech Giants Index",
    "rhTECH",
    [tslaAddr, amznAddr, pltrAddr],
    [
      hre.ethers.parseEther("10"),  // 10 TSLA per INDEX
      hre.ethers.parseEther("15"),  // 15 AMZN per INDEX
      hre.ethers.parseEther("50"),  // 50 PLTR per INDEX
    ],
    ["TSLA", "AMZN", "PLTR"],
    30  // 0.3% fee
  );
  await indexFund.waitForDeployment();
  console.log("rhTECH Index Fund:", await indexFund.getAddress());

  // ── 4. RH Lending Pool ────────────────────────────────────────────
  console.log("\n--- Deploying RH Lending Pool ---");
  const LendingPool = await hre.ethers.getContractFactory("RHLendingPool");
  const lendingPool = await LendingPool.deploy(
    await oracle.getAddress(),
    500,  // 5% annual interest
    500   // 5% liquidation bonus
  );
  await lendingPool.waitForDeployment();
  const lendingAddr = await lendingPool.getAddress();
  console.log("Lending Pool:", lendingAddr);

  // Configure collateral tokens
  await (await lendingPool.configureToken(tslaAddr, "TSLA", 18, 7500, 8500)).wait();
  await (await lendingPool.configureToken(amznAddr, "AMZN", 18, 7000, 8000)).wait();
  await (await lendingPool.configureToken(pltrAddr, "PLTR", 18, 6000, 7500)).wait();
  console.log("Collateral configured: TSLA(75% LTV), AMZN(70% LTV), PLTR(60% LTV)");

  // Seed lending pool with ETH liquidity
  await (await lendingPool.depositLiquidity({ value: hre.ethers.parseEther("0.005") })).wait();
  console.log("Pool seeded with 0.005 ETH liquidity");

  // ── 5. RH Stock Option Market ─────────────────────────────────────
  console.log("\n--- Deploying RH Stock Option Market ---");
  const OptionMarket = await hre.ethers.getContractFactory("RHStockOption");
  const optionMarket = await OptionMarket.deploy(100); // 1% protocol fee
  await optionMarket.waitForDeployment();
  console.log("Option Market:", await optionMarket.getAddress());

  // ── Summary ───────────────────────────────────────────────────────
  const explorer = "https://explorer.testnet.chain.robinhood.com/address";
  console.log("\n========================================");
  console.log("   RobinDeFi Protocol - DEPLOYED");
  console.log("========================================\n");
  console.log("Mock Tokens:");
  console.log(`  TSLA: ${tslaAddr}`);
  console.log(`  AMZN: ${amznAddr}`);
  console.log(`  PLTR: ${pltrAddr}`);
  console.log(`\nInfrastructure:`);
  console.log(`  Oracle:        ${await oracle.getAddress()}`);
  console.log(`\nCore Protocol:`);
  console.log(`  Index Fund:    ${await indexFund.getAddress()}`);
  console.log(`  Lending Pool:  ${lendingAddr}`);
  console.log(`  Option Market: ${await optionMarket.getAddress()}`);
  console.log(`\nExplorer:`);
  console.log(`  ${explorer}/${await indexFund.getAddress()}`);
  console.log(`  ${explorer}/${lendingAddr}`);
  console.log(`  ${explorer}/${await optionMarket.getAddress()}`);

  // Return addresses for demo script
  return {
    tsla: tslaAddr,
    amzn: amznAddr,
    pltr: pltrAddr,
    oracle: await oracle.getAddress(),
    indexFund: await indexFund.getAddress(),
    lendingPool: lendingAddr,
    optionMarket: await optionMarket.getAddress(),
  };
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
