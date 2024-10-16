// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/utils/ReentrancyGuard.sol";

interface IFlashLoanReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

contract Market is ReentrancyGuard {
    address public lendingAsset;
    address public borrowingAsset;
    uint256 public collateralRatio;
    uint256 public constant FLASH_LOAN_FEE = 9; // 0.09% fee
    uint256 public constant FLASH_LOAN_FEE_PRECISION = 10000;

    // Interest rate model parameters
    uint256 public constant OPTIMAL_UTILIZATION = 80; // 80%
    uint256 public constant BASE_RATE = 0; // 0%
    uint256 public constant SLOPE1 = 4; // 4%
    uint256 public constant SLOPE2 = 75; // 75%
    uint256 public constant UTILIZATION_PRECISION = 100;

    uint256 public totalDeposits;
    uint256 public totalBorrows;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public borrows;

    // Custom Errors
    error ZeroAmount();
    error InsufficientCollateral();
    error InsufficientBalance();
    error RepayAmountExceedsBorrowed();
    error WithdrawalLeavesInsufficientCollateral();
    error PositionNotUndercollateralized();
    error UnsupportedAsset();
    error InsufficientLiquidity();
    error FlashLoanRepaymentFailed();
    error FlashLoanNotRepaid();

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 amount);
    event FlashLoan(address indexed receiver, address indexed asset, uint256 amount, uint256 fee);

    constructor(address _lendingAsset, address _borrowingAsset, uint256 _collateralRatio) {
        lendingAsset = _lendingAsset;
        borrowingAsset = _borrowingAsset;
        collateralRatio = _collateralRatio;
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(lendingAsset).transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] = deposits[msg.sender] + amount;
        totalDeposits = totalDeposits + (amount);
        emit Deposited(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 requiredCollateral = amount * (collateralRatio) / 100;
        if (deposits[msg.sender] < requiredCollateral) revert InsufficientCollateral();

        borrows[msg.sender] = borrows[msg.sender] + (amount);
        totalBorrows = totalBorrows + (amount);
        IERC20(borrowingAsset).transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (borrows[msg.sender] < amount) revert RepayAmountExceedsBorrowed();

        IERC20(borrowingAsset).transferFrom(msg.sender, address(this), amount);
        borrows[msg.sender] = borrows[msg.sender] - (amount);
        totalBorrows = totalBorrows - (amount);
        emit Repaid(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (deposits[msg.sender] < amount) revert InsufficientBalance();

        uint256 borrowedAmount = borrows[msg.sender];
        uint256 requiredCollateral = borrowedAmount * (collateralRatio) / (100);
        if (deposits[msg.sender] - (amount) < requiredCollateral) revert WithdrawalLeavesInsufficientCollateral();

        deposits[msg.sender] = deposits[msg.sender] - (amount);
        totalDeposits = totalDeposits - (amount);
        IERC20(lendingAsset).transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function liquidate(address borrower) external nonReentrant {
        uint256 borrowedAmount = borrows[borrower];
        uint256 collateralValue = deposits[borrower];
        uint256 requiredCollateral = borrowedAmount * (collateralRatio) / (100);

        if (collateralValue >= requiredCollateral) revert PositionNotUndercollateralized();

        // Calculate the amount to liquidate (for simplicity, we'll liquidate the entire position)
        uint256 amountToLiquidate = borrowedAmount;

        // Transfer the borrowed asset from the liquidator to the contract
        IERC20(borrowingAsset).transferFrom(msg.sender, address(this), amountToLiquidate);

        // Transfer the collateral to the liquidator
        IERC20(lendingAsset).transfer(msg.sender, collateralValue);

        // Clear the borrower's position
        borrows[borrower] = 0;
        deposits[borrower] = 0;
        totalBorrows = totalBorrows - (borrowedAmount);
        totalDeposits = totalDeposits - (collateralValue);

        emit Liquidated(borrower, msg.sender, amountToLiquidate);
    }

    function flashLoan(address receiver, address asset, uint256 amount, bytes calldata params) external nonReentrant {
        if (asset != lendingAsset && asset != borrowingAsset) revert UnsupportedAsset();
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        if (balanceBefore < amount) revert InsufficientLiquidity();

        uint256 fee = amount * (FLASH_LOAN_FEE) / (FLASH_LOAN_FEE_PRECISION);

        IERC20(asset).transfer(receiver, amount);

        bool success = IFlashLoanReceiver(receiver).executeOperation(asset, amount, fee, msg.sender, params);
        if (!success) revert FlashLoanRepaymentFailed();

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter < balanceBefore + (fee)) revert FlashLoanNotRepaid();

        emit FlashLoan(receiver, asset, amount, fee);
    }

    // New functions for the interest rate model

    function getUtilizationRate() public view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return totalBorrows * (UTILIZATION_PRECISION) / (totalDeposits);
    }

    function getBorrowRate() public view returns (uint256) {
        uint256 utilization = getUtilizationRate();
        if (utilization <= OPTIMAL_UTILIZATION) {
            return BASE_RATE + (utilization * (SLOPE1) / (OPTIMAL_UTILIZATION));
        } else {
            return BASE_RATE + (SLOPE1)
                + ((utilization - (OPTIMAL_UTILIZATION)) * (SLOPE2) / (UTILIZATION_PRECISION - (OPTIMAL_UTILIZATION)));
        }
    }

    function getSupplyRate() public view returns (uint256) {
        uint256 utilizationRate = getUtilizationRate();
        uint256 borrowRate = getBorrowRate();
        return utilizationRate * (borrowRate) / (UTILIZATION_PRECISION);
    }
}
