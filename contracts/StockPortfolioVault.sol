// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StockPortfolioVault
 * @notice Multi-asset vault for Robinhood Chain Stock Tokens & ETH.
 *         Deposit, track, time-lock, and withdraw a portfolio of assets.
 * @dev Designed for Robinhood Chain Testnet (Arbitrum Orbit L2, chainId 46630).
 */
contract StockPortfolioVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Types ───────────────────────────────────────────────────────────
    struct TokenInfo {
        string symbol;
        bool    isActive;
    }

    struct UserPortfolio {
        uint256 ethBalance;
        uint256 totalDeposits;
        uint256 lastDepositTime;
    }

    // ── State ───────────────────────────────────────────────────────────
    address public owner;
    uint256 public withdrawalDelay; // seconds after last deposit before withdrawal allowed
    bool    public paused;

    address[] public supportedTokens;
    mapping(address => TokenInfo) public tokenInfo;

    // user => token => balance
    mapping(address => mapping(address => uint256)) public tokenBalances;
    // user => portfolio meta
    mapping(address => UserPortfolio) public portfolios;

    uint256 public totalUsers;
    mapping(address => bool) private knownUsers;

    // ── Events ──────────────────────────────────────────────────────────
    event Deposited(address indexed user, address indexed token, uint256 amount);
    event DepositedETH(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event WithdrawnETH(address indexed user, uint256 amount);
    event TokenAdded(address indexed token, string symbol);
    event TokenRemoved(address indexed token);
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event WithdrawalDelayUpdated(uint256 newDelay);
    event Paused(bool isPaused);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault paused");
        _;
    }

    modifier withdrawalUnlocked() {
        require(
            block.timestamp >= portfolios[msg.sender].lastDepositTime + withdrawalDelay,
            "Withdrawal locked"
        );
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(uint256 _withdrawalDelay) {
        owner = msg.sender;
        withdrawalDelay = _withdrawalDelay;
    }

    // ── Admin ───────────────────────────────────────────────────────────
    function addToken(address _token, string calldata _symbol) external onlyOwner {
        require(!tokenInfo[_token].isActive, "Already added");
        tokenInfo[_token] = TokenInfo(_symbol, true);
        supportedTokens.push(_token);
        emit TokenAdded(_token, _symbol);
    }

    function removeToken(address _token) external onlyOwner {
        require(tokenInfo[_token].isActive, "Not active");
        tokenInfo[_token].isActive = false;
        emit TokenRemoved(_token);
    }

    function setWithdrawalDelay(uint256 _delay) external onlyOwner {
        withdrawalDelay = _delay;
        emit WithdrawalDelayUpdated(_delay);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // ── Deposits ────────────────────────────────────────────────────────
    function depositETH() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "Zero ETH");
        _trackUser(msg.sender);

        portfolios[msg.sender].ethBalance += msg.value;
        portfolios[msg.sender].totalDeposits++;
        portfolios[msg.sender].lastDepositTime = block.timestamp;

        emit DepositedETH(msg.sender, msg.value);
    }

    function depositToken(address _token, uint256 _amount) external whenNotPaused nonReentrant {
        require(tokenInfo[_token].isActive, "Token not supported");
        require(_amount > 0, "Zero amount");
        _trackUser(msg.sender);

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        tokenBalances[msg.sender][_token] += _amount;
        portfolios[msg.sender].totalDeposits++;
        portfolios[msg.sender].lastDepositTime = block.timestamp;

        emit Deposited(msg.sender, _token, _amount);
    }

    // ── Withdrawals ─────────────────────────────────────────────────────
    function withdrawETH(uint256 _amount) external whenNotPaused nonReentrant withdrawalUnlocked {
        require(_amount > 0 && _amount <= portfolios[msg.sender].ethBalance, "Bad amount");

        portfolios[msg.sender].ethBalance -= _amount;
        (bool sent, ) = msg.sender.call{value: _amount}("");
        require(sent, "ETH transfer failed");

        emit WithdrawnETH(msg.sender, _amount);
    }

    function withdrawToken(address _token, uint256 _amount) external whenNotPaused nonReentrant withdrawalUnlocked {
        require(tokenInfo[_token].isActive, "Token not supported");
        require(_amount > 0 && _amount <= tokenBalances[msg.sender][_token], "Bad amount");

        tokenBalances[msg.sender][_token] -= _amount;
        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Withdrawn(msg.sender, _token, _amount);
    }

    // ── Emergency (owner) ───────────────────────────────────────────────
    function emergencyWithdrawETH() external onlyOwner {
        uint256 bal = address(this).balance;
        (bool sent, ) = owner.call{value: bal}("");
        require(sent, "ETH transfer failed");
        emit EmergencyWithdraw(address(0), bal);
    }

    function emergencyWithdrawToken(address _token) external onlyOwner {
        uint256 bal = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(owner, bal);
        emit EmergencyWithdraw(_token, bal);
    }

    // ── Views ───────────────────────────────────────────────────────────
    function getPortfolio(address _user)
        external
        view
        returns (
            uint256 ethBalance,
            uint256 totalDeposits,
            uint256 lastDepositTime,
            uint256 timeUntilUnlock
        )
    {
        UserPortfolio storage p = portfolios[_user];
        uint256 unlockTime = p.lastDepositTime + withdrawalDelay;
        uint256 remaining = block.timestamp >= unlockTime ? 0 : unlockTime - block.timestamp;
        return (p.ethBalance, p.totalDeposits, p.lastDepositTime, remaining);
    }

    function getTokenBalance(address _user, address _token) external view returns (uint256) {
        return tokenBalances[_user][_token];
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function getSupportedTokenCount() external view returns (uint256) {
        return supportedTokens.length;
    }

    // ── Internal ────────────────────────────────────────────────────────
    function _trackUser(address _user) internal {
        if (!knownUsers[_user]) {
            knownUsers[_user] = true;
            totalUsers++;
        }
    }

    receive() external payable {
        _trackUser(msg.sender);
        portfolios[msg.sender].ethBalance += msg.value;
        portfolios[msg.sender].totalDeposits++;
        portfolios[msg.sender].lastDepositTime = block.timestamp;
        emit DepositedETH(msg.sender, msg.value);
    }
}
