// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/Market.sol";
import "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000e18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockFlashLoanReceiver is IFlashLoanReceiver {
    bool public shouldRepay;

    constructor(bool _shouldRepay) {
        shouldRepay = _shouldRepay;
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (shouldRepay) {
            IERC20(asset).transfer(msg.sender, amount + premium);
        }
        return shouldRepay;
    }
}

contract MarketTest is Test {
    Market public market;
    MockERC20 public lendingToken;
    MockERC20 public borrowingToken;
    address public owner;
    address public user1;
    address public user2;

    uint256 public constant INTEREST_RATE = 500; // 5%
    uint256 public constant COLLATERAL_RATIO = 150; // 150%

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);

        lendingToken = new MockERC20("Lending Token", "LTK");
        borrowingToken = new MockERC20("Borrowing Token", "BTK");

        market = new Market(address(lendingToken), address(borrowingToken), INTEREST_RATE, COLLATERAL_RATIO);

        lendingToken.mint(user1, 1000e18);
        lendingToken.mint(user2, 1000e18);
        borrowingToken.mint(address(market), 10000e18);
    }

    function testDeposit() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 100e18);
        market.deposit(100e18);
        vm.stopPrank();

        assertEq(market.deposits(user1), 100e18);
        assertEq(lendingToken.balanceOf(address(market)), 100e18);
    }

    function testDepositZeroAmount() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 100e18);
        vm.expectRevert(abi.encodeWithSelector(Market.ZeroAmount.selector));
        market.deposit(0);
        vm.stopPrank();
    }

    function testBorrow() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 150e18);
        market.deposit(150e18);
        market.borrow(100e18);
        vm.stopPrank();

        assertEq(market.borrows(user1), 100e18);
        assertEq(borrowingToken.balanceOf(user1), 100e18);
    }

    function testBorrowInsufficientCollateral() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 100e18);
        market.deposit(100e18);
        vm.expectRevert(abi.encodeWithSelector(Market.InsufficientCollateral.selector));
        market.borrow(100e18);
        vm.stopPrank();
    }

    function testRepay() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 150e18);
        market.deposit(150e18);
        market.borrow(100e18);
        borrowingToken.approve(address(market), 50e18);
        market.repay(50e18);
        vm.stopPrank();

        assertEq(market.borrows(user1), 50e18);
        assertEq(borrowingToken.balanceOf(address(market)), 9950e18);
    }

    function testRepayExceedsBorrowed() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 150e18);
        market.deposit(150e18);
        market.borrow(100e18);
        borrowingToken.approve(address(market), 150e18);
        vm.expectRevert(abi.encodeWithSelector(Market.RepayAmountExceedsBorrowed.selector));
        market.repay(150e18);
        vm.stopPrank();
    }

    function testWithdraw() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 150e18);
        market.deposit(150e18);
        market.withdraw(50e18);
        vm.stopPrank();

        assertEq(market.deposits(user1), 100e18);
        assertEq(lendingToken.balanceOf(user1), 900e18);
    }

    function testWithdrawInsufficientBalance() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 100e18);
        market.deposit(100e18);
        vm.expectRevert(abi.encodeWithSelector(Market.InsufficientBalance.selector));
        market.withdraw(150e18);
        vm.stopPrank();
    }

    function testLiquidate() public {
        vm.startPrank(user1);
        lendingToken.approve(address(market), 150e18);
        market.deposit(150e18);
        market.borrow(100e18);
        vm.stopPrank();

        // Simulate price change making the position undercollateralized
        market = new Market(
            address(lendingToken),
            address(borrowingToken),
            INTEREST_RATE,
            200 // New collateral ratio
        );

        vm.startPrank(user2);
        borrowingToken.approve(address(market), 100e18);
        market.liquidate(user1);
        vm.stopPrank();

        assertEq(market.deposits(user1), 0);
        assertEq(market.borrows(user1), 0);
        assertEq(lendingToken.balanceOf(user2), 1150e18);
    }

    function testFlashLoan() public {
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(true);
        borrowingToken.transfer(address(receiver), 1e18); // Send some tokens to cover the fee

        vm.prank(address(receiver));
        borrowingToken.approve(address(market), 1e18);

        market.flashLoan(address(receiver), address(borrowingToken), 1000e18, "");

        assertEq(borrowingToken.balanceOf(address(market)), 10000e18 + 1e18 * 9 / 10000);
    }

    function testFlashLoanFailedRepayment() public {
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(false);

        vm.expectRevert(abi.encodeWithSelector(Market.FlashLoanRepaymentFailed.selector));
        market.flashLoan(address(receiver), address(borrowingToken), 1000e18, "");
    }

    function testFuzzDeposit(uint256 amount) public {
        amount = bound(amount, 1, 1000e18);

        vm.startPrank(user1);
        lendingToken.approve(address(market), amount);
        market.deposit(amount);
        vm.stopPrank();

        assertEq(market.deposits(user1), amount);
        assertEq(lendingToken.balanceOf(address(market)), amount);
    }

    function testFuzzBorrowAndRepay(uint256 depositAmount, uint256 borrowAmount, uint256 repayAmount) public {
        depositAmount = bound(depositAmount, 100e18, 1000e18);
        borrowAmount = bound(borrowAmount, 1e18, depositAmount * 100 / COLLATERAL_RATIO);
        repayAmount = bound(repayAmount, 1, borrowAmount);

        vm.startPrank(user1);
        lendingToken.approve(address(market), depositAmount);
        market.deposit(depositAmount);
        market.borrow(borrowAmount);
        borrowingToken.approve(address(market), repayAmount);
        market.repay(repayAmount);
        vm.stopPrank();

        assertEq(market.deposits(user1), depositAmount);
        assertEq(market.borrows(user1), borrowAmount - repayAmount);
    }

    function testFuzzLiquidation(uint256 depositAmount, uint256 borrowAmount, uint256 newCollateralRatio) public {
        depositAmount = bound(depositAmount, 100e18, 1000e18);
        borrowAmount = bound(borrowAmount, depositAmount * 100 / COLLATERAL_RATIO, depositAmount * 99 / 100);
        newCollateralRatio = bound(newCollateralRatio, COLLATERAL_RATIO + 1, 300);

        vm.startPrank(user1);
        lendingToken.approve(address(market), depositAmount);
        market.deposit(depositAmount);
        market.borrow(borrowAmount);
        vm.stopPrank();

        // Simulate price change making the position undercollateralized
        market = new Market(address(lendingToken), address(borrowingToken), INTEREST_RATE, newCollateralRatio);

        vm.startPrank(user2);
        borrowingToken.approve(address(market), borrowAmount);
        market.liquidate(user1);
        vm.stopPrank();

        assertEq(market.deposits(user1), 0);
        assertEq(market.borrows(user1), 0);
        assertEq(lendingToken.balanceOf(user2), 1000e18 + depositAmount);
    }
}
