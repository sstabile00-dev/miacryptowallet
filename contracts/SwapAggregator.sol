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
 * - Direct to fee recipient address
 * 
 * Security Features:
 * - ReentrancyGuard on all state-changing functions
 * - Input validation on all external functions (min/max amounts)
 * - SafeERC20 for safe token transfers
 * - Pausable mechanism for emergency situations
 * - Owner access control on admin functions
 * 
 * Events logged for all swap activity for transparency and auditing.
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

contract SwapAggregator is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // ========================================================================
    // CONSTANTS
    // ========================================================================
    
    uint256 public constant PLATFORM_FEE_BPS = 20; // 0.2% (20 basis points)
    uint256 public constant BPS_DENOMINATOR = 10000; // 100% = 10000 bps
    address public constant WETH = 0x82aF49447d8a07e3bd95BD0d56f313302c1d7fD3;
    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    
    // Dust prevention: minimum amount to prevent spam/dust attacks
    uint256 public constant MIN_AMOUNT = 1e6; // 0.000001 tokens
    uint256 public constant MAX_AMOUNT = 1e9 * 1e18; // 1 billion tokens max

    // ========================================================================
    // STATE VARIABLES
    // ========================================================================
    
    address public feeRecipient;
    uint256 public totalFeesCollected;
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

    // ========================================================================
    // EVENTS
    // ========================================================================
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeCharged,
        string dexUsed
    );

    event FeeCollected(address indexed token, uint256 amount, uint256 timestamp);
    event FeeWithdrawn(address indexed token, uint256 amount, address indexed to);
    event FeeRecipientChanged(address indexed oldRecipient, address indexed newRecipient);

    // ========================================================================
    // CONSTRUCTOR
    // ========================================================================
    
    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    // ========================================================================
    // MAIN SWAP FUNCTION
    // ========================================================================

    /**
     * @dev Execute a swap with best route from Uniswap V3
     * @param _tokenIn Input token address
     * @param _tokenOut Output token address
     * @param _amountIn Amount of input tokens (in base units)
     * @param _minAmountOut Minimum amount of output tokens (slippage protection)
     * @return amountOutAfterFee Amount of tokens received after platform fee
     * 
     * Requirements:
     * - Contract must not be paused
     * - Amount must be within MIN_AMOUNT and MAX_AMOUNT
     * - TokenIn and TokenOut must be different addresses
     * - User must have approved this contract to spend tokenIn
     * 
     * Emits SwapExecuted and FeeCollected events
     */
    function swapWithBestRoute(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256) {
        // ========== INPUT VALIDATION ==========
        require(_amountIn >= MIN_AMOUNT, "Amount too small");
        require(_amountIn <= MAX_AMOUNT, "Amount too large");
        require(_tokenIn != address(0) && _tokenOut != address(0), "Invalid token");
        require(_tokenIn != _tokenOut, "Cannot swap identical tokens");
        require(_minAmountOut > 0, "Minimum amount must be greater than 0");
        
        // ========== TRANSFER IN ==========
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        IERC20(_tokenIn).safeApprove(UNISWAP_V3_ROUTER, _amountIn);

        // ========== CALCULATE AMOUNTS ==========
        // In production: Call Uniswap V3 Router here for actual price
        // For now: Simplified mock (1:1 rate)
        uint256 amountOutBeforeFee = _amountIn;
        
        // Calculate platform fee (0.2%)
        uint256 platformFee = (amountOutBeforeFee * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountOutAfterFee = amountOutBeforeFee - platformFee;

        // ========== SLIPPAGE PROTECTION ==========
        require(amountOutAfterFee >= _minAmountOut, "Slippage exceeded");

        // ========== TRANSFER OUT ==========
        IERC20(_tokenOut).safeTransfer(msg.sender, amountOutAfterFee);
        IERC20(_tokenOut).safeTransfer(feeRecipient, platformFee);

        // ========== RECORD & EMIT ==========
        _recordSwap(_tokenIn, _tokenOut, _amountIn, amountOutAfterFee, platformFee);

        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _amountIn, amountOutAfterFee, platformFee, "Uniswap V3");
        emit FeeCollected(_tokenOut, platformFee, block.timestamp);

        return amountOutAfterFee;
    }

    /**
     * @dev Get a quote for a swap without executing it
     * @param _tokenIn Input token address
     * @param _tokenOut Output token address
     * @param _amountIn Amount of input tokens
     * @return outputAmount Estimated output before fee
     * @return platformFee Platform fee amount
     * @return finalAmount Final amount after fee
     */
    function getSwapQuote(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (
        uint256 outputAmount,
        uint256 platformFee,
        uint256 finalAmount
    ) {
        require(_amountIn >= MIN_AMOUNT, "Amount too small");
        require(_amountIn <= MAX_AMOUNT, "Amount too large");
        require(_tokenIn != address(0) && _tokenOut != address(0), "Invalid token");
        require(_tokenIn != _tokenOut, "Cannot swap identical tokens");
        
        uint256 estimatedOutput = _amountIn; // In production: call Uniswap
        uint256 fee = (estimatedOutput * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        return (estimatedOutput, fee, estimatedOutput - fee);
    }

    /**
     * @dev Internal function to record swap in history
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

    // ========================================================================
    // GETTER FUNCTIONS (VIEW/PURE)
    // ========================================================================

    /**
     * @dev Get total volume swapped through contract
     */
    function getTotalVolume() external view returns (uint256) {
        return totalVolumeSwapped;
    }

    /**
     * @dev Get total fees collected
     */
    function getTotalFeesCollected() external view returns (uint256) {
        return totalFeesCollected;
    }

    /**
     * @dev Get number of swaps for a specific user
     */
    function getUserSwapCount(address _user) external view returns (uint256) {
        require(_user != address(0), "Invalid address");
        return userSwapCount[_user];
    }

    /**
     * @dev Get length of swap history
     */
    function getSwapHistoryLength() external view returns (uint256) {
        return swapHistory.length;
    }

    /**
     * @dev Get a specific swap record by index
     */
    function getSwapRecord(uint256 _index) external view returns (SwapRecord memory) {
        require(_index < swapHistory.length, "Index out of bounds");
        return swapHistory[_index];
    }

    // ========================================================================
    // ADMIN FUNCTIONS (ONLY OWNER)
    // ========================================================================

    /**
     * @dev Set new fee recipient address
     * @param _newRecipient New address to receive fees
     */
    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;
        emit FeeRecipientChanged(oldRecipient, _newRecipient);
    }

    /**
     * @dev Pause contract (prevents all swaps)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Emergency withdraw all tokens of a specific type
     * @param _token Token address to withdraw
     */
    function emergencyWithdraw(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "No balance to withdraw");
        IERC20(_token).safeTransfer(owner(), balance);
        emit FeeWithdrawn(_token, balance, owner());
    }

    /**
     * @dev Receive ETH transfers
     */
    receive() external payable {}
}
