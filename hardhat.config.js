import "@nomicfoundation/hardhat-toolbox";
import dotenv from "dotenv";
dotenv.config();

export default {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    robinhoodTestnet: {
      url: "https://rpc.testnet.chain.robinhood.com",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 46630,
    },
  },
  etherscan: {
    apiKey: {
      robinhoodTestnet: "empty",
    },
    customChains: [
      {
        network: "robinhoodTestnet",
        chainId: 46630,
        urls: {
          apiURL: "https://explorer.testnet.chain.robinhood.com/api",
          browserURL: "https://explorer.testnet.chain.robinhood.com",
        },
      },
    ],
  },
};
