const hre = require('hardhat');

async function main() {
  console.log('🚀 Deploying SwapAggregator to Arbitrum Sepolia...');
  
  const feeRecipient = process.env.FEE_RECIPIENT || (await hre.ethers.getSigners())[0].address;
  console.log('Fee recipient:', feeRecipient);
  
  const SwapAggregator = await hre.ethers.getContractFactory('SwapAggregator');
  const contract = await SwapAggregator.deploy(feeRecipient);
  await contract.deployed();
  
  console.log('✅ SwapAggregator deployed to:', contract.address);
  console.log('\n📋 Deployment Info:');
  console.log('- Contract:', contract.address);
  console.log('- Fee Recipient:', feeRecipient);
  console.log('- Platform Fee: 0.2%');
  console.log('\n🔗 Explorer: https://sepolia.arbiscan.io/address/' + contract.address);
  
  // Save to .env
  const fs = require('fs');
  const envContent = fs.readFileSync('.env', 'utf8');
  const updatedEnv = envContent.replace(/CONTRACT_ADDRESS=.*/, `CONTRACT_ADDRESS=${contract.address}`);
  fs.writeFileSync('.env', updatedEnv);
  
  console.log('\n✅ .env updated with contract address');
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
