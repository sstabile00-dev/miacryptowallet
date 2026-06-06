const express = require('express');
const cors = require('cors');
const ethers = require('ethers');
require('dotenv').config();

const app = express();
app.use(cors());
app.use(express.json());

// Contract setup
const ARBITRUM_RPC = process.env.ARBITRUM_RPC_URL;
const CONTRACT_ADDRESS = process.env.CONTRACT_ADDRESS;
const PRIVATE_KEY = process.env.PRIVATE_KEY;

const provider = new ethers.providers.JsonRpcProvider(ARBITRUM_RPC);
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

const CONTRACT_ABI = [
  "function getTotalVolume() public view returns (uint256)",
  "function getTotalFeesCollected() public view returns (uint256)",
  "function getSwapHistoryLength() public view returns (uint256)",
  "function getSwapRecord(uint256 _index) public view returns (tuple(address,address,address,uint256,uint256,uint256,uint256))"
];

const contract = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, signer);

// Routes
app.get('/api/stats', async (req, res) => {
  try {
    const volume = await contract.getTotalVolume();
    const fees = await contract.getTotalFeesCollected();
    const historyLength = await contract.getSwapHistoryLength();
    
    res.json({
      totalVolume: ethers.utils.formatEther(volume),
      totalFees: ethers.utils.formatEther(fees),
      totalSwaps: historyLength.toString(),
      feePercentage: 0.2
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/swaps/:page', async (req, res) => {
  try {
    const page = parseInt(req.params.page) || 0;
    const perPage = 10;
    const total = await contract.getSwapHistoryLength();
    
    const swaps = [];
    const start = Math.max(0, total.toNumber() - (page + 1) * perPage);
    const end = Math.max(0, total.toNumber() - page * perPage);
    
    for (let i = start; i < end; i++) {
      const record = await contract.getSwapRecord(i);
      swaps.push({
        user: record[0],
        tokenIn: record[1],
        tokenOut: record[2],
        amountIn: ethers.utils.formatEther(record[3]),
        amountOut: ethers.utils.formatEther(record[4]),
        feeCharged: ethers.utils.formatEther(record[5]),
        timestamp: new Date(record[6].toNumber() * 1000)
      });
    }
    
    res.json({ swaps, page, total: total.toNumber() });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/quote/:tokenIn/:tokenOut/:amount', async (req, res) => {
  try {
    const { tokenIn, tokenOut, amount } = req.params;
    const amountWei = ethers.utils.parseEther(amount);
    
    // Mock quote (production: use Uniswap Quoter)
    const fee = amountWei.mul(20).div(10000); // 0.2%
    const output = amountWei.sub(fee);
    
    res.json({
      inputAmount: amount,
      estimatedOutput: ethers.utils.formatEther(output),
      platformFee: ethers.utils.formatEther(fee),
      feePercentage: 0.2
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`CryptoSwap API running on port ${PORT}`));
