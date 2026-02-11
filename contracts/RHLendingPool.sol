// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./SimplePriceOracle.sol";

/**
 * @title RHLendingPool
 * @author RobinDeFi Protocol
 * @notice Collateralized lending: deposit Stock Tokens, borrow ETH.
 *
 *  Problem:  Traditional margin accounts require $25k minimum balance,
 *            complex applications, and opaque risk management.
 *
 *  Solution: Deposit any supported stock token as collateral and instantly
 *            borrow ETH up to the loan-to-value ratio. Fully transparent
 *            liquidation. No minimums. No paperwork.
 *
 *  Revenue:  Interest on borrows + liquidation penalties.
 *
 * @dev Uses SimplePriceOracle for collateral valuation.
 *      Production version would integrate Chainlink or Robinhood's oracle.
 */
contract RHLendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Position {
        address collateralToken;
        uint256 collateralAmount;
        uint256 debtETH;           // ETH borrowed (wei)
        uint256 borrowTimestamp;
    }

    struct TokenConfig {
        bool    isActive;
        uint8   decimals;
        uint256 ltvBps;            // max loan-to-value (e.g., 7500 = 75%)
        uint256 liquidationBps;    // liquidation threshold (e.g., 8500 = 85%)
        string  symbol;
    }

    // ── State ───────────────────────────────────────────────────────────
    address public owner;
    SimplePriceOracle public oracle;
    bool    public paused;

    uint256 public interestRateBps;     // annual interest (e.g., 500 = 5%)
    uint256 public liquidationBonusBps; // bonus for liquidators (e.g., 500 = 5%)
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    mapping(address => TokenConfig) public tokenConfigs;
    address[] public supportedTokens;

    // user => position ID => Position
    mapping(address => Position[]) public positions;

    uint256 public totalBorrowed;
    uint256 public totalLiquidated;
    uint256 public totalInterestCollected;

    // ── Events ──────────────────────────────────────────────────────────
    event CollateralDeposited(address indexed user, uint256 positionId, address token, uint256 amount);
    event Borrowed(address indexed user, uint256 positionId, uint256 ethAmount);
    event Repaid(address indexed user, uint256 positionId, uint256 ethAmount, uint256 interest);
    event Liquidated(address indexed liquidator, address indexed user, uint256 positionId, uint256 debtRepaid, uint256 collateralSeized);
    event TokenConfigured(address indexed token, string symbol, uint256 ltvBps, uint256 liquidationBps);

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Pool paused");
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address oracle_,
        uint256 interestRateBps_,
        uint256 liquidationBonusBps_
    ) {
        owner = msg.sender;
        oracle = SimplePriceOracle(oracle_);
        interestRateBps = interestRateBps_;
        liquidationBonusBps = liquidationBonusBps_;
    }

    // ── Admin ───────────────────────────────────────────────────────────
    function configureToken(
        address token,
        string calldata symbol,
        uint8  decimals_,
        uint256 ltvBps,
        uint256 liquidationBps
    ) external onlyOwner {
        require(ltvBps < liquidationBps, "LTV must be < liquidation");
        require(liquidationBps <= 9500, "Liquidation too high");

        if (!tokenConfigs[token].isActive) {
            supportedTokens.push(token);
        }
        tokenConfigs[token] = TokenConfig({
            isActive: true,
            decimals: decimals_,
            ltvBps: ltvBps,
            liquidationBps: liquidationBps,
            symbol: symbol
        });
        emit TokenConfigured(token, symbol, ltvBps, liquidationBps);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /// @notice Deposit ETH into the pool as lending liquidity
    function depositLiquidity() external payable onlyOwner {
        require(msg.value > 0, "Zero ETH");
    }

    // ── User: Open Position ─────────────────────────────────────────────
    /// @notice Deposit collateral and borrow ETH in one transaction.
    /// @param token Collateral token address
    /// @param collateralAmount Amount of collateral to deposit
    /// @param borrowAmount ETH to borrow (wei)
    function openPosition(
        address token,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) external whenNotPaused nonReentrant {
        TokenConfig storage config = tokenConfigs[token];
        require(config.isActive, "Token not supported");
        require(collateralAmount > 0, "Zero collateral");

        // Transfer collateral in
        IERC20(token).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Create position
        uint256 posId = positions[msg.sender].length;
        positions[msg.sender].push(Position({
            collateralToken: token,
            collateralAmount: collateralAmount,
            debtETH: 0,
            borrowTimestamp: block.timestamp
        }));

        emit CollateralDeposited(msg.sender, posId, token, collateralAmount);

        // Borrow if requested
        if (borrowAmount > 0) {
            _borrow(msg.sender, posId, borrowAmount);
        }
    }

    /// @notice Borrow additional ETH against an existing position.
    function borrow(uint256 positionId, uint256 amount) external whenNotPaused nonReentrant {
        _borrow(msg.sender, positionId, amount);
    }

    /// @notice Repay debt and reclaim collateral.
    function repay(uint256 positionId) external payable whenNotPaused nonReentrant {
        Position storage pos = positions[msg.sender][positionId];
        require(pos.collateralAmount > 0, "No position");

        uint256 interest = _calculateInterest(pos);
        uint256 totalOwed = pos.debtETH + interest;
        require(msg.value >= totalOwed, "Insufficient repayment");

        // Return collateral
        IERC20(pos.collateralToken).safeTransfer(msg.sender, pos.collateralAmount);

        // Refund excess ETH
        uint256 excess = msg.value - totalOwed;
        if (excess > 0) {
            (bool sent, ) = msg.sender.call{value: excess}("");
            require(sent, "ETH refund failed");
        }

        totalInterestCollected += interest;

        emit Repaid(msg.sender, positionId, pos.debtETH, interest);

        // Clear position
        pos.collateralAmount = 0;
        pos.debtETH = 0;
    }

    // ── Liquidation ─────────────────────────────────────────────────────
    /// @notice Liquidate an undercollateralized position.
    /// @dev Anyone can call this. Liquidator repays debt, receives collateral + bonus.
    function liquidate(address user, uint256 positionId) external payable nonReentrant {
        Position storage pos = positions[user][positionId];
        require(pos.collateralAmount > 0, "No position");
        require(pos.debtETH > 0, "No debt");

        TokenConfig storage config = tokenConfigs[pos.collateralToken];

        // Check if position is undercollateralized
        uint256 collateralValueETH = oracle.getValueInEth(
            pos.collateralToken,
            pos.collateralAmount,
            config.decimals
        );
        uint256 liquidationThreshold = (collateralValueETH * config.liquidationBps) / 10000;
        uint256 interest = _calculateInterest(pos);
        uint256 totalDebt = pos.debtETH + interest;

        require(totalDebt >= liquidationThreshold, "Position healthy");

        // Liquidator repays the debt
        require(msg.value >= totalDebt, "Insufficient liquidation payment");

        // Liquidator receives collateral (all of it — includes implicit bonus)
        IERC20(pos.collateralToken).safeTransfer(msg.sender, pos.collateralAmount);

        // Refund excess
        uint256 excess = msg.value - totalDebt;
        if (excess > 0) {
            (bool sent, ) = msg.sender.call{value: excess}("");
            require(sent, "ETH refund failed");
        }

        totalLiquidated += totalDebt;
        totalInterestCollected += interest;

        emit Liquidated(msg.sender, user, positionId, totalDebt, pos.collateralAmount);

        // Clear position
        pos.collateralAmount = 0;
        pos.debtETH = 0;
    }

    // ── Views ───────────────────────────────────────────────────────────
    function getPositionCount(address user) external view returns (uint256) {
        return positions[user].length;
    }

    function getPositionHealth(address user, uint256 positionId)
        external
        view
        returns (
            uint256 collateralValueETH,
            uint256 totalDebt,
            uint256 healthFactor, // > 10000 = healthy, < 10000 = liquidatable
            bool    isLiquidatable
        )
    {
        Position storage pos = positions[user][positionId];
        if (pos.collateralAmount == 0 || pos.debtETH == 0) {
            return (0, 0, type(uint256).max, false);
        }

        TokenConfig storage config = tokenConfigs[pos.collateralToken];
        collateralValueETH = oracle.getValueInEth(
            pos.collateralToken,
            pos.collateralAmount,
            config.decimals
        );

        uint256 interest = _calculateInterest(pos);
        totalDebt = pos.debtETH + interest;

        if (totalDebt == 0) {
            healthFactor = type(uint256).max;
        } else {
            healthFactor = (collateralValueETH * config.liquidationBps) / totalDebt;
        }

        uint256 threshold = (collateralValueETH * config.liquidationBps) / 10000;
        isLiquidatable = totalDebt >= threshold;
    }

    function getMaxBorrow(address token, uint256 collateralAmount) external view returns (uint256) {
        TokenConfig storage config = tokenConfigs[token];
        if (!config.isActive) return 0;
        uint256 valueETH = oracle.getValueInEth(token, collateralAmount, config.decimals);
        return (valueETH * config.ltvBps) / 10000;
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    // ── Internal ────────────────────────────────────────────────────────
    function _borrow(address user, uint256 positionId, uint256 amount) internal {
        Position storage pos = positions[user][positionId];
        TokenConfig storage config = tokenConfigs[pos.collateralToken];

        uint256 collateralValueETH = oracle.getValueInEth(
            pos.collateralToken,
            pos.collateralAmount,
            config.decimals
        );
        uint256 maxBorrow = (collateralValueETH * config.ltvBps) / 10000;
        uint256 interest = _calculateInterest(pos);

        require(pos.debtETH + interest + amount <= maxBorrow, "Exceeds LTV");
        require(address(this).balance >= amount, "Insufficient pool liquidity");

        pos.debtETH += interest + amount;
        pos.borrowTimestamp = block.timestamp;

        totalBorrowed += amount;

        (bool sent, ) = user.call{value: amount}("");
        require(sent, "ETH transfer failed");

        emit Borrowed(user, positionId, amount);
    }

    function _calculateInterest(Position storage pos) internal view returns (uint256) {
        if (pos.debtETH == 0 || pos.borrowTimestamp == 0) return 0;
        uint256 elapsed = block.timestamp - pos.borrowTimestamp;
        return (pos.debtETH * interestRateBps * elapsed) / (10000 * SECONDS_PER_YEAR);
    }

    receive() external payable {}
}
