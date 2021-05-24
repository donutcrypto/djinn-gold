const HDWalletProvider = require("@truffle/hdwallet-provider");
const Web3 = require("web3");
const fs = require("fs");
const devkey = fs.readFileSync(".devkey").toString().trim();
const { infuraProjectId, infuraSecret } = require('./.secrets.json');

async function check_provider() {
  const test_provider = new HDWalletProvider({privateKeys: [devkey], providerOrUrl: "https://bsc-dataseed1.binance.org"});
  const web3 = new Web3(test_provider);
}

module.exports = {
  compilers: {
    solc: {
      version: "0.7.6",
    },
  },
  "optimizer": {
    "enabled": true,
    "runs": 9999
  },
  // Uncommenting the defaults below 
  // provides for an easier quick-start with Ganache.
  // You can also follow this format for other networks;
  // see <http://truffleframework.com/docs/advanced/configuration>
  // for more details on how to specify configuration options!
  networks: {
    development: {
      host: "127.0.0.1",
      port: 7545,
      network_id: "*"
    },
    ropsten: {
      provider: () => new HDWalletProvider(mnemonic, `https://ropsten.infura.io/v3/${projectId}`),
      network_id: 3,       // Ropsten's id
      gas: 5500000,        // Ropsten has a lower block limit than mainnet
      confirmations: 2,    // # of confs to wait between deployments. (default: 0)
      timeoutBlocks: 200,  // # of blocks before a deployment times out  (minimum/default: 50)
      skipDryRun: true     // Skip dry run before migrations? (default: false for public nets )
    },
    bsc: {
      provider: new HDWalletProvider({privateKeys: [devkey], providerOrUrl: "https://bsc-dataseed1.binance.org"}),
      network_id: 56,
      confirmations: 10,
      timeoutBlocks: 200,
      skipDryRun: true
    }
  },
  plugins: [
    'truffle-plugin-verify'
  ],
  api_keys: {
    bscscan: process.env.BSCSCAN_API_KEY
  }
};
