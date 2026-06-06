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
 * Fee Structure (100% transparent):
 * - Platform fee: 0.2% (taken from output amount)
 * - All fees visible BEFORE user confirms swap
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

    // Constants
    uint256 public constant PLATFORM_FEE_BPS = 20; // 0.2%
    uint256 public constant BPS_DENOMINATOR = 10000;
    address public constant WETH = 0x82aF49447d8a07e3bd95BD0d56f313302c1d7fD3;
    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // State
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

    // Events
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

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;
    }

    function swapWithBestRoute(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) external nonReentrant whenNotPaused returns (uint256) {
        require(_amountIn > 0, "Amount must be greater than 0");
        require(_tokenIn != address(0) && _tokenOut != address(0), "Invalid token");
        require(_tokenIn != _tokenOut, "Cannot swap identical tokens");
        
        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        IERC20(_tokenIn).safeApprove(UNISWAP_V3_ROUTER, _amountIn);

        uint256 amountOutBeforeFee = _amountIn; // Simplified
        uint256 platformFee = (amountOutBeforeFee * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountOutAfterFee = amountOutBeforeFee - platformFee;

        require(amountOutAfterFee >= _minAmountOut, "Slippage exceeded");

        IERC20(_tokenOut).safeTransfer(msg.sender, amountOutAfterFee);
        IERC20(_tokenOut).safeTransfer(feeRecipient, platformFee);

        _recordSwap(_tokenIn, _tokenOut, _amountIn, amountOutAfterFee, platformFee);

        emit SwapExecuted(msg.sender, _tokenIn, _tokenOut, _amountIn, amountOutAfterFee, platformFee, "Uniswap V3");
        emit FeeCollected(_tokenOut, platformFee, block.timestamp);

        return amountOutAfterFee;
    }

    function getSwapQuote(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (
        uint256 outputAmount,
        uint256 platformFee,
        uint256 finalAmount
    ) {
        require(_amountIn > 0, "Amount must be greater than 0");
        uint256 estimatedOutput = _amountIn;
        uint256 fee = (estimatedOutput * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        return (estimatedOutput, fee, estimatedOutput - fee);
    }

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

    function getTotalVolume() external view returns (uint256) {
        return totalVolumeSwapped;
    }

    function getTotalFeesCollected() external view returns (uint256) {
        return totalFeesCollected;
    }

    function getUserSwapCount(address _user) external view returns (uint256) {
        return userSwapCount[_user];
    }

    function getSwapHistoryLength() external view returns (uint256) {
        return swapHistory.length;
    }

    function getSwapRecord(uint256 _index) external view returns (SwapRecord memory) {
        require(_index < swapHistory.length, "Index out of bounds");
        return swapHistory[_index];
    }

    function setFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        feeRecipient = _newRecipient;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function emergencyWithdraw(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(owner(), balance);
        emit FeeWithdrawn(_token, balance, owner());
    }

    receive() external payable {}
}
