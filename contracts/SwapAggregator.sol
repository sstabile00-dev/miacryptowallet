// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title SwapAggregator
 * @dev Transparent, multi-DEX swap aggregator for Arbitrum
 * 
 * Fee Structure (100% transparent):
 * - Platform fee: 0.2% (taken from output amount)
 * - All fees visible BEFORE user confirms swap
 * - No hidden fees or MEV extraction
 */

interface ISwapRouter {
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    struct ExactInputSingleParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract SwapAggregator is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ==================== CONSTANTS ====================
    uint256 public constant PLATFORM_FEE_BPS = 20; // 0.2% = 20 basis points
    uint256 public constant BPS_DENOMINATOR = 10000;
    address public constant WETH = 0x82aF49447d8a07e3bd95BD0d56f313302c1d7fD3; // Arbitrum WETH
    
    // DEX Router addresses on Arbitrum
    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant CURVE_POOL = 0x7f90122bf63538F5Fcb6467eb6D48127423eee94; // USDC/USDT pool

    // ==================== STATE ====================
    address public feeRecipient;
    uint256 public totalFeesCollected; // For transparency
    uint256 public totalVolumeSwapped;
    
    mapping(address => uint256) public userSwapCount;
    
    struct SwapRecord {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeCharged;
        uint256 timestamp;
    }
    
    SwapRecord[] public swapHistory;

    // ==================== EVENTS ====================
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeCharged,
        string dexUsed
    );

    event FeeCollected(
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FeeWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed to
    );

    // ==================== MODIFIERS ====================
    modifier validTokens(address _tokenIn, address _tokenOut) {
        require(_tokenIn != address(0) && _tokenOut != address(0), "Invalid token address");
        require(_tokenIn != _tokenOut, "Cannot swap identical tokens");
        _;
    }

    // ==================== CONSTRUCTOR ====================
    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    // ==================== MAIN SWAP LOGIC ====================

    /**
     * @dev Execute swap with best route across multiple DEXs
     * @param _tokenIn Input token address
     * @param _tokenOut Output token address
     * @param _amountIn Amount of input tokens
     * @param _minAmountOut Minimum acceptable output (slippage protection)
     * @return amountOut Final amount received after platform fee
     */
    function swapWithBestRoute(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external nonReentrant whenNotPaused validTokens(_tokenIn, _tokenOut) returns (uint256) {
        require(_amountIn > 0, "Amount must be greater than 0");
        
        // Step 1: Transfer tokens from user to this contract
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);

        // Step 2: Approve DEX routers (simplified for MVP)
        IERC20(_tokenIn).safeApprove(UNISWAP_V3_ROUTER, _amountIn);

        // Step 3: Execute swap on Uniswap V3 (primary DEX)
        uint256 amountOutBeforeFee = _executeUniswapSwap(_tokenIn, _tokenOut, _amountIn);

        // Step 4: Calculate and deduct platform fee (0.2%)
        uint256 platformFee = (amountOutBeforeFee * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountOutAfterFee = amountOutBeforeFee - platformFee;

        // Step 5: Verify slippage tolerance
        require(amountOutAfterFee >= _minAmountOut, "Slippage tolerance exceeded");

        // Step 6: Transfer output to user
        IERC20(_tokenOut).safeTransfer(msg.sender, amountOutAfterFee);

        // Step 7: Transfer fee to fee vault (for transparency tracking)
        IERC20(_tokenOut).safeTransfer(feeRecipient, platformFee);

        // Step 8: Record transaction (for analytics & transparency)
        _recordSwap(_tokenIn, _tokenOut, _amountIn, amountOutAfterFee, platformFee);

        // Step 9: Emit event with all details visible
        emit SwapExecuted(
            msg.sender,
            _tokenIn,
            _tokenOut,
            _amountIn,
            amountOutAfterFee,
            platformFee,
            "Uniswap V3"
        );

        emit FeeCollected(_tokenOut, platformFee, block.timestamp);

        return amountOutAfterFee;
    }

    // ==================== DEX INTEGRATION ====================

    /**
     * @dev Execute swap on Uniswap V3
     * Simplified version - production would use quoter for better pricing
     */
    function _executeUniswapSwap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal returns (uint256) {
        // This is simplified - production would include proper path encoding
        // For now, return a mock value to show the flow
        // Real implementation: use Uniswap QuoterV2 for accurate quotes
        
        // Placeholder for actual Uniswap call
        // In production: calculate optimal fee tier (500, 3000, or 10000 bps)
        
        return _amountIn; // Mock return - replace with actual swap
    }

    // ==================== QUOTE FUNCTION ====================

    /**
     * @dev Get quote for swap (no slippage, user sees exact fee)
     * @return quoteData Structure with all fee breakdowns
     */
    function getSwapQuote(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (
        uint256 outputAmount,
        uint256 platformFee,
        uint256 dexFee,
        uint256 finalAmount,
        string memory dexUsed
    ) {
        require(_amountIn > 0, "Amount must be greater than 0");

        // Mock quote (production: actual price oracle)
        uint256 estimatedOutput = _amountIn; // Simplified

        // Calculate transparent fees
        uint256 fee = (estimatedOutput * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 final = estimatedOutput - fee;

        return (
            estimatedOutput,
            fee,
            0, // DEX fee (already included in estimatedOutput)
            final,
            "Uniswap V3"
        );
    }

    // ==================== ANALYTICS & TRANSPARENCY ====================

    /**
     * @dev Record swap for complete transparency
     */
    function _recordSwap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOut,
        uint256 _feeCharged
    ) internal {
        swapHistory.push(SwapRecord({
            user: msg.sender,
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            amountIn: _amountIn,
            amountOut: _amountOut,
            feeCharged: _feeCharged,
            timestamp: block.timestamp
        }));

        totalFeesCollected += _feeCharged;
        totalVolumeSwapped += _amountIn;
        userSwapCount[msg.sender]++;
    }

    /**
     * @dev Get total swap volume (public transparency)
     */
    function getTotalVolume() external view returns (uint256) {
        return totalVolumeSwapped;
    }

    /**
     * @dev Get total fees collected (public transparency)
     */
    function getTotalFeesCollected() external view returns (uint256) {
        return totalFeesCollected;
    }

    /**
     * @dev Get user swap history
     */
    function getUserSwapCount(address _user) external view returns (uint256) {
        return userSwapCount[_user];
    }

    /**
     * @dev Get swap history length
     */
    function getSwapHistoryLength() external view returns (uint256) {
        return swapHistory.length;
    }

    /**
     * @dev Get specific swap record
     */
    function getSwapRecord(uint256 _index) external view returns (SwapRecord memory) {
        require(_index < swapHistory.length, "Index out of bounds");
        return swapHistory[_index];
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @dev Update fee recipient (multisig in production)
     */
    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        feeRecipient = _newRecipient;
    }

    /**
     * @dev Emergency pause (in case of exploit)
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Withdraw stuck ERC20 tokens (not user funds)
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(owner(), balance);
        emit FeeWithdrawn(_token, balance, owner());
    }

    // ==================== RECEIVE ETH ====================
    receive() external payable {}
}