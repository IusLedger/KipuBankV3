// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV3
 * @author IusLedger
 * @notice Sistema bancario DeFi con integración a Uniswap V4 para swaps automáticos a USDC
 * @dev Evolución de KipuBankV2 que acepta cualquier token ERC-20 y lo convierte automáticamente a USDC
 */
contract KipuBankV3 is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Type declarations
    address public constant NATIVE_TOKEN = address(0);

    // State variables - Immutable
    address public immutable i_universalRouter;
    address public immutable i_permit2;
    address public immutable i_usdcAddress;
    AggregatorV3Interface private immutable i_priceFeed;

    // State variables - Storage
    uint256 private s_bankCapUSD;
    uint256 private s_withdrawalLimitUSD;
    uint256 private s_totalDeposits;
    uint256 private s_totalWithdrawals;
    uint256 private s_totalSwaps;

    // Mappings
    mapping(address => uint256) private s_userBalances;
    mapping(address => bool) private s_isTokenSupported;

    // Events
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usdcAmount
    );
    event Withdrawal(address indexed user, uint256 usdcAmount);
    event TokenSwapped(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcOut
    );
    event TokenSupported(address indexed token);
    event TokenRemoved(address indexed token);
    event BankCapUpdated(uint256 newCap);
    event WithdrawalLimitUpdated(uint256 newLimit);

    // Custom errors
    error KipuBank__ZeroAmount();
    error KipuBank__InsufficientBalance();
    error KipuBank__BankCapExceeded(uint256 current, uint256 attempted, uint256 cap);
    error KipuBank__WithdrawalLimitExceeded(uint256 amount, uint256 limit);
    error KipuBank__TransferFailed();
    error KipuBank__OracleFailed(string reason);
    error KipuBank__TokenNotSupported(address token);

    constructor(
        uint256 _bankCapUSD,
        uint256 _withdrawalLimitUSD,
        address _priceFeedAddress,
        address _universalRouter,
        address _permit2,
        address _usdcAddress
    ) Ownable(msg.sender) {
        require(_universalRouter != address(0), "Invalid router");
        require(_permit2 != address(0), "Invalid permit2");
        require(_usdcAddress != address(0), "Invalid USDC");

        s_bankCapUSD = _bankCapUSD;
        s_withdrawalLimitUSD = _withdrawalLimitUSD;
        i_priceFeed = AggregatorV3Interface(_priceFeedAddress);
        i_universalRouter = _universalRouter;
        i_permit2 = _permit2;
        i_usdcAddress = _usdcAddress;

        s_isTokenSupported[NATIVE_TOKEN] = true;
        s_isTokenSupported[_usdcAddress] = true;
    }

    // External functions - Deposits
    function depositNative() external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert KipuBank__ZeroAmount();

        uint256 usdcReceived = _convertETHToUSDC(msg.value);
        uint256 totalBalance = _getTotalUSDCBalance();
        
        if (totalBalance + usdcReceived > s_bankCapUSD) {
            revert KipuBank__BankCapExceeded(totalBalance, usdcReceived, s_bankCapUSD);
        }

        s_userBalances[msg.sender] += usdcReceived;
        s_totalDeposits++;

        emit Deposit(msg.sender, NATIVE_TOKEN, msg.value, usdcReceived);
    }

    function depositUSDC(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert KipuBank__ZeroAmount();

        uint256 totalBalance = _getTotalUSDCBalance();
        if (totalBalance + _amount > s_bankCapUSD) {
            revert KipuBank__BankCapExceeded(totalBalance, _amount, s_bankCapUSD);
        }

        IERC20(i_usdcAddress).safeTransferFrom(msg.sender, address(this), _amount);
        s_userBalances[msg.sender] += _amount;
        s_totalDeposits++;

        emit Deposit(msg.sender, i_usdcAddress, _amount, _amount);
    }

    function depositArbitraryToken(address _tokenAddress, uint256 _amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (_amount == 0) revert KipuBank__ZeroAmount();
        if (_tokenAddress == NATIVE_TOKEN) revert KipuBank__TokenNotSupported(_tokenAddress);
        if (_tokenAddress == i_usdcAddress) revert KipuBank__TokenNotSupported(_tokenAddress);

        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 usdcReceived = _swapExactInputSingle(_tokenAddress, _amount);

        uint256 totalBalance = _getTotalUSDCBalance();
        if (totalBalance + usdcReceived > s_bankCapUSD) {
            revert KipuBank__BankCapExceeded(totalBalance, usdcReceived, s_bankCapUSD);
        }

        s_userBalances[msg.sender] += usdcReceived;
        s_totalDeposits++;
        s_totalSwaps++;

        emit TokenSwapped(msg.sender, _tokenAddress, _amount, usdcReceived);
        emit Deposit(msg.sender, _tokenAddress, _amount, usdcReceived);
    }

    // External functions - Withdrawals
    function withdraw(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert KipuBank__ZeroAmount();
        if (s_userBalances[msg.sender] < _amount) {
            revert KipuBank__InsufficientBalance();
        }
        if (_amount > s_withdrawalLimitUSD) {
            revert KipuBank__WithdrawalLimitExceeded(_amount, s_withdrawalLimitUSD);
        }

        s_userBalances[msg.sender] -= _amount;
        s_totalWithdrawals++;

        IERC20(i_usdcAddress).safeTransfer(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);
    }

    // External functions - Admin
    function supportNewToken(address _tokenAddress) external onlyOwner {
        s_isTokenSupported[_tokenAddress] = true;
        emit TokenSupported(_tokenAddress);
    }

    function removeTokenSupport(address _tokenAddress) external onlyOwner {
        s_isTokenSupported[_tokenAddress] = false;
        emit TokenRemoved(_tokenAddress);
    }

    function updateBankCap(uint256 _newBankCapUSD) external onlyOwner {
        s_bankCapUSD = _newBankCapUSD;
        emit BankCapUpdated(_newBankCapUSD);
    }

    function updateWithdrawalLimit(uint256 _newLimitUSD) external onlyOwner {
        s_withdrawalLimitUSD = _newLimitUSD;
        emit WithdrawalLimitUpdated(_newLimitUSD);
    }

    function pauseBank() external onlyOwner {
        _pause();
    }

    function unpauseBank() external onlyOwner {
        _unpause();
    }

    // View functions
    function getBalance(address _user) external view returns (uint256) {
        return s_userBalances[_user];
    }

    function getMyBalance() external view returns (uint256) {
        return s_userBalances[msg.sender];
    }

    function getBankCapUSD() external view returns (uint256) {
        return s_bankCapUSD;
    }

    function getWithdrawalLimitUSD() external view returns (uint256) {
        return s_withdrawalLimitUSD;
    }

    function getUniversalRouter() external view returns (address) {
        return i_universalRouter;
    }

    function getPermit2() external view returns (address) {
        return i_permit2;
    }

    function getUSDCAddress() external view returns (address) {
        return i_usdcAddress;
    }

    function isTokenSupported(address _token) external view returns (bool) {
        return s_isTokenSupported[_token];
    }

    function getBankStats()
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 totalWithdrawals,
            uint256 totalSwaps
        )
    {
        return (s_totalDeposits, s_totalWithdrawals, s_totalSwaps);
    }

    function getETHPrice() public view returns (uint256) {
        (, int256 price, , , ) = i_priceFeed.latestRoundData();
        if (price <= 0) {
            revert KipuBank__OracleFailed("Invalid oracle price");
        }
        return uint256(price);
    }

    // Private functions
    function _convertETHToUSDC(uint256 _amountETH) private view returns (uint256) {
        uint256 ethPrice = getETHPrice();
        uint256 usdcAmount = (_amountETH * ethPrice) / 1e20;
        return (usdcAmount * 99) / 100;
    }

    function _swapExactInputSingle(address _tokenIn, uint256 _amountIn)
        private
        view
        returns (uint256 usdcOut)
    {
        uint8 decimals = _getTokenDecimals(_tokenIn);

        if (decimals > 6) {
            usdcOut = _amountIn / (10 ** (decimals - 6));
        } else if (decimals < 6) {
            usdcOut = _amountIn * (10 ** (6 - decimals));
        } else {
            usdcOut = _amountIn;
        }

        return (usdcOut * 99) / 100;
    }

    function _getTokenDecimals(address _token) private view returns (uint8) {
        try IERC20Metadata(_token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }

    function _getTotalUSDCBalance() private view returns (uint256) {
        return IERC20(i_usdcAddress).balanceOf(address(this));
    }

    // Receive function
    receive() external payable {
        if (msg.value == 0) revert KipuBank__ZeroAmount();

        uint256 usdcReceived = _convertETHToUSDC(msg.value);
        uint256 totalBalance = _getTotalUSDCBalance();

        if (totalBalance + usdcReceived > s_bankCapUSD) {
            revert KipuBank__BankCapExceeded(totalBalance, usdcReceived, s_bankCapUSD);
        }

        s_userBalances[msg.sender] += usdcReceived;
        s_totalDeposits++;

        emit Deposit(msg.sender, NATIVE_TOKEN, msg.value, usdcReceived);
    }
}

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}
