// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../contracts/CustodialVault.sol";

contract MockPyth is IPyth {
    mapping(bytes32 => Price) public prices;
    mapping(bytes32 => bool) public priceSet;

    function setPriceUnsafe(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        prices[id] = Price(price, conf, expo, publishTime);
        priceSet[id] = true;
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory price) {
        if (priceSet[id]) {
            return prices[id];
        }
        // Return default price if not set
        return Price(10000000000, 1000000, -8, block.timestamp);
    }

    function getPrice(bytes32 id) external view override returns (Price memory price) {
        if (priceSet[id]) {
            return prices[id];
        }
        return Price(10000000000, 1000000, -8, block.timestamp);
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {}

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 0.001 ether;
    }
    
    function parsePriceFeedUpdates(
        bytes[] calldata,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64
    ) external payable override returns (IPyth.PriceFeed[] memory priceFeeds) {
        priceFeeds = new IPyth.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            IPyth.Price memory priceData;
            if (priceSet[priceIds[i]]) {
                // Return the stored price if it matches the time range
                if (prices[priceIds[i]].publishTime >= minPublishTime) {
                    priceData = prices[priceIds[i]];
                } else {
                    // Return a price with the requested timestamp
                    priceData = IPyth.Price(
                        prices[priceIds[i]].price,
                        prices[priceIds[i]].conf,
                        prices[priceIds[i]].expo,
                        minPublishTime + 30 // Middle of the time range
                    );
                }
            } else {
                // Return default price with requested timestamp
                priceData = IPyth.Price(10000000000, 1000000, -8, minPublishTime + 30);
            }
            // Create PriceFeed with price and emaPrice (using same values for simplicity)
            priceFeeds[i] = IPyth.PriceFeed({
                id: priceIds[i],
                price: priceData,
                emaPrice: priceData
            });
        }
        return priceFeeds;
    }
}

contract CustodialVaultTest is Test {
    CustodialVault public vault;
    MockPyth public mockPyth;
    
    // Add receive function to accept refunds
    receive() external payable {}

    address constant BORROWER = address(0x1);
    address constant LENDER = address(0x2);
    address constant OTHER_USER = address(0x3);
    address constant RECIPIENT = address(0x4);
    // vault.IP_PRICE_FEED_ID() is now hardcoded in CustodialVault contract
    // bytes32: 0xb620ba83044577029da7e4ded7a2abccf8e6afc2a0d4d26d89ccdd39ec109025

    uint256 constant LIQUIDATION_PRICE = 50e18; // $50 with 18 decimals
    uint256 constant TOTAL_TOKEN_AMOUNT = 10 ether;
    uint256 constant LOCK_DURATION = 30 days; // 1 month for testing

    event TokensWithdrawnByBorrower(address indexed borrower, address indexed recipient, uint256 amount);
    event TokensWithdrawnByLender(address indexed lender, uint256 amount, uint256 currentPrice);
    event PriceUpdated(uint256 price, uint256 timestamp);

    function setUp() public {
        // Deploy mock Pyth oracle at the expected address (Aeneid testnet)
        mockPyth = MockPyth(address(0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320));
        vm.etch(address(mockPyth), type(MockPyth).runtimeCode);

        // Deploy CustodialVault without lock end time
        vault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );

        // Fund test accounts
        vm.deal(BORROWER, 100 ether);
        vm.deal(LENDER, 100 ether);
        vm.deal(OTHER_USER, 100 ether);
        
        // Deposit and start the vault by default for most tests
        vm.prank(BORROWER);
        vault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        vm.prank(BORROWER);
        vault.ackLoanReceived();
    }

    function testReceiveFunds() public {
        // Test that vault can receive funds via receive function
        uint256 sendAmount = 1 ether;
        payable(address(vault)).transfer(sendAmount);
        assertEq(address(vault).balance, TOTAL_TOKEN_AMOUNT + sendAmount);
    }

    function testAckLoanReceived() public {
        // Create a new vault that hasn't been started
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Check initial state
        assertEq(newVault.started(), false);
        assertEq(newVault.lockEndTime(), 0);
        
        // Try to acknowledge principal received without deposit - should fail
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.NotDeposited.selector);
        newVault.ackLoanReceived();
        
        // Deposit first
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Acknowledge principal received
        vm.prank(BORROWER);
        newVault.ackLoanReceived();
        
        // Check state after acknowledgment
        assertEq(newVault.started(), true);
        assertEq(newVault.lockEndTime(), block.timestamp + 8 * 30 days);
    }

    function testAckLoanReceivedNotAuthorized() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Try to acknowledge principal received as lender
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        newVault.ackLoanReceived();
        
        // Try to acknowledge principal received as other user
        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        newVault.ackLoanReceived();
    }

    function testAckLoanReceivedAlreadyStarted() public {
        // Vault is already started in setUp
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.AlreadyStarted.selector);
        vault.ackLoanReceived();
    }

    function testDepositCollateral() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Check initial state
        assertEq(newVault.depositTime(), 0);
        assertEq(address(newVault).balance, 0);
        
        // Deposit
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Check state after deposit
        assertEq(newVault.depositTime(), block.timestamp);
        assertEq(address(newVault).balance, TOTAL_TOKEN_AMOUNT);
    }

    function testDepositCollateralNotAuthorized() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Try to deposit as lender
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Try to deposit as other user
        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
    }

    function testDepositCollateralAlreadyDeposited() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // First deposit
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Try to deposit again
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.AlreadyDeposited.selector);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
    }

    function testDepositCollateralZeroAmount() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Try to deposit zero amount
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        newVault.depositCollateral{value: 0}();
    }

    function testWithdrawByBorrowerWithinGracePeriod() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Deposit
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Try to withdraw within 3 days - should fail
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        newVault.withdrawByBorrower(BORROWER);
        
        // Try again after 2 days - still should fail
        vm.warp(block.timestamp + 2 days);
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        newVault.withdrawByBorrower(BORROWER);
    }

    function testWithdrawByBorrowerAfterGracePeriod() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Deposit
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Try to withdraw exactly at 3 days - should fail (still within period)
        vm.warp(block.timestamp + 3 days);
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        newVault.withdrawByBorrower(BORROWER);
        
        // Fast forward past grace period (3 days + 1 second)
        vm.warp(block.timestamp + 1);
        
        // Foundation can withdraw after grace period if ackLoanReceived() not called
        vm.prank(BORROWER);
        newVault.withdrawByBorrower(BORROWER);
        
        // Verify withdrawal
        assertTrue(newVault.withdrawn());
        assertEq(address(newVault).balance, 0);
    }
    
    function testWithdrawByBorrowerAfterStart() public {
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Deposit
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Acknowledge principal received
        vm.prank(BORROWER);
        newVault.ackLoanReceived();
        
        // Foundation cannot withdraw after start
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        newVault.withdrawByBorrower(BORROWER);
    }

    function testWithdrawByBorrowerNotDeposited() public {
        // Create a new vault without deposit
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Try to withdraw without depositing
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.NotDeposited.selector);
        newVault.withdrawByBorrower(BORROWER);
    }


    function testConstructorValidation() public {
        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        new CustodialVault(address(0), LENDER, LIQUIDATION_PRICE, TOTAL_TOKEN_AMOUNT);

        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        new CustodialVault(BORROWER, address(0), LIQUIDATION_PRICE, TOTAL_TOKEN_AMOUNT);

        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        new CustodialVault(BORROWER, LENDER, 0, TOTAL_TOKEN_AMOUNT);

        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        new CustodialVault(BORROWER, LENDER, LIQUIDATION_PRICE, 0);

        // Lock end time validation is now done in ackLoanReceived() function
    }

    function testWithdrawByBorrowerAfterLockWithApproval() public {
        // Vault already has tokens from setUp

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Foundation cannot withdraw after ackLoanReceived() has been called
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        vault.withdrawByBorrower(RECIPIENT);

        // Verify vault still has funds
        assertEq(address(vault).balance, TOTAL_TOKEN_AMOUNT);
        (,,,,,bool isWithdrawn,) = vault.getVaultDetails();
        assertEq(isWithdrawn, false);
    }

    function testWithdrawByBorrowerBeforeLockPeriod() public {
        // Vault already has tokens from setUp

        // Try to withdraw after start - borrower cannot withdraw once started
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        vault.withdrawByBorrower(RECIPIENT);
    }

    function testWithdrawByBorrowerWithoutLenderApproval() public {
        // Vault already has tokens from setUp

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Try to withdraw - borrower cannot withdraw after start
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        vault.withdrawByBorrower(RECIPIENT);
    }

    function testWithdrawByBorrowerNotAuthorized() public {
        // Vault already has tokens from setUp

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Try to withdraw as different user
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.withdrawByBorrower(RECIPIENT);
    }

    function testWithdrawByBorrowerInvalidRecipient() public {
        // Create new vault without calling start
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Deposit tokens as borrower
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Wait 3 days (borrower can withdraw after 3 days if not started)
        vm.warp(block.timestamp + 3 days + 1);

        // Try to withdraw to zero address
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        newVault.withdrawByBorrower(address(0));
    }



    function testWithdrawByLenderOnPriceDrop() public {
        // Vault already has tokens from setUp

        // Build full 24 hours of price history at liquidation price
        for (uint256 i = 0; i < 1440; i++) { // 24 hours = 1440 minutes
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 5000000000; // $50 = liquidation price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            
            // Update price every minute to fill ring buffer
            vault.updatePrice();
        }

        // Request liquidation first
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation time window
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
        assertEq(address(vault).balance, 0);

        (,,,,,bool isWithdrawn,) = vault.getVaultDetails();
        assertEq(isWithdrawn, true);
    }

    function testWithdrawByLenderInsufficientPriceHistory() public {
        // Vault already has tokens from setUp

        // Build some price history but not enough (less than 1440 points)
        for (uint256 i = 0; i < 1000; i++) { // Only 1000 points, need 1440
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InsufficientPriceHistory.selector);
        vault.requestLiquidation();
    }

    function testWithdrawByLenderPriceDropNotMet() public {
        // Vault already has tokens from setUp

        // Build full price history with small decline (not enough for 50% drop)
        for (uint256 i = 0; i < 1440; i++) { // Full 24 hours
            vm.warp(block.timestamp + 1 minutes);
            
            // Set price to 60% of initial (40% drop, not enough)
            uint256 targetPrice = LIQUIDATION_PRICE + 10e18; // Above liquidation price
            int64 pythPrice = int64(uint64(targetPrice / 1e10));
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            
            // Update price to fill the ring buffer
            vault.updatePrice();
        }

        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.PriceDropThresholdNotMet.selector);
        vault.requestLiquidation();
    }

    function testWithdrawByLenderAfterLockEnd() public {
        // Vault already has tokens from setUp

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        // Lender should be able to withdraw after lock end without restrictions
        vm.prank(LENDER);
        vm.expectEmit(true, false, false, true);
        emit TokensWithdrawnByLender(LENDER, TOTAL_TOKEN_AMOUNT, 0); // price is 0 for post-lock withdrawals
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
        assertTrue(vault.withdrawn());
    }

    function testWithdrawByLenderNotAuthorized() public {
        // Vault already has tokens from setUp

        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.withdrawByLender();
    }

    // Helper function to send funds to vault the old way (before deposit function)
    // This simulates legacy behavior for specific test cases
    function sendFundsDirectly(address vaultAddress, uint256 amount) internal {
        // For smaller amounts (fees), direct transfer should work
        if (amount <= 0.1 ether) {
            payable(vaultAddress).transfer(amount);
        } else {
            // For larger amounts, we need to use deposit if testing the main vault
            // For testing purposes, we can force funds in
            vm.deal(vaultAddress, vaultAddress.balance + amount);
        }
    }

    function testDoubleWithdrawal() public {
        // Test double withdrawal with lender instead
        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // First withdrawal by lender
        vm.prank(LENDER);
        vault.withdrawByLender();

        // Try to withdraw again
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.withdrawByLender();

        // Foundation also cannot withdraw after lender withdrew
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.withdrawByBorrower(RECIPIENT);
    }

    function testGetVaultDetails() public {
        (uint256 initPrice, uint256 tokenAmount, uint256 lockEnd, uint256 depositTimestamp, bool isStarted, bool isWithdrawn, uint256 currentBalance) = vault.getVaultDetails();
        assertEq(initPrice, LIQUIDATION_PRICE);
        assertEq(tokenAmount, TOTAL_TOKEN_AMOUNT);
        assertEq(lockEnd, vault.lockEndTime());
        assertEq(isWithdrawn, false);
        assertEq(currentBalance, TOTAL_TOKEN_AMOUNT); // Vault already has tokens from setUp
    }

    function testTWAPCalculation() public {
        // Send tokens to vault to trigger price updates
        payable(address(vault)).transfer(1 ether);

        // Add price history
        uint256[] memory prices = new uint256[](5);
        prices[0] = 100e18;
        prices[1] = 95e18;
        prices[2] = 90e18;
        prices[3] = 85e18;
        prices[4] = 80e18;

        for (uint256 i = 0; i < prices.length; i++) {
            vm.warp(block.timestamp + 2 minutes);
            int64 pythPrice = int64(uint64(prices[i] / 1e10));
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            
            // Trigger price update
            vault.updatePrice();
        }

        uint256 twap = vault.getCurrentTWAP();
        // TWAP should be between the highest and lowest price
        assertGt(twap, 79e18);
        assertLt(twap, 101e18);
    }

    function testStaleOraclePrice() public {
        // Vault already has tokens from setUp

        // Build full price history first (24 hours)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Wait to make price history stale (must be more than 1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        // Try to request liquidation - should fail due to stale price history
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault.requestLiquidation();
    }

    function testPriceUpdate() public {
        // Check initial price history length
        assertEq(vault.getPriceHistoryLength(), 0);

        // Update prices multiple times with time gaps
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 2 minutes);
            vault.updatePrice();
        }

        // Price history should have been updated
        assertGt(vault.getPriceHistoryLength(), 0);
    }


    function testNegativePriceRejected() public {
        // Set negative price in mock
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), -1000000000, 1000000, -8, block.timestamp);
        
        // Try to update price - should fail
        vm.warp(block.timestamp + 2 minutes);
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.updatePrice();
    }

    // Regression Tests
    
    function testRegressionWithdrawByLenderNoParams() public {
        // Test that withdrawByLender() without parameters succeeds
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history at 40% price
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Request liquidation first
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender(); // No parameters
        
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
    }
    
    function testRegressionStaleToFreshWorkflow() public {
        // Test: Liquidation request fails due to stale price → refreshFeedsAndUpdatePrice → request succeeds
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Wait to make price stale (more than 1 hour)
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Request liquidation should fail due to stale price
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault.requestLiquidation();
        
        // Refresh price - need to update the mock price timestamp too
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
        vault.updatePrice();
        
        // Now liquidation request should succeed
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Now withdrawal should succeed
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
    }
    
    
    function testRegression24HourWindowBoundaries() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Test "not yet full" - 1439 points (1 short of full)
        for (uint256 i = 0; i < 1439; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InsufficientPriceHistory.selector);
        vault.requestLiquidation();
        
        // Add one more point to reach exactly 1440
        vm.warp(block.timestamp + 1 minutes);
        vault.updatePrice();
        
        // Now liquidation request should succeed with exactly full buffer
        vm.prank(LENDER);
        vault.requestLiquidation();
        assertTrue(vault.liquidationRequestActive());
        
        // Wait for liquidation window and withdraw
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
        assertEq(vault.getPriceHistoryLength(), 1440); // Exactly full
    }
    
    function testRegressionMaxPriceAgeBoundary() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Test 1: Oracle price at exactly MAX_PRICE_AGE (5 minutes) - should succeed
        vm.warp(block.timestamp + 1 minutes);
        vault.updatePrice(); // Keep history fresh
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp - 5 minutes);
        
        // Request liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
        
        // Test 2: Create new vault for testing stale oracle price
        CustodialVault vault2 = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        vm.prank(BORROWER);
        vault2.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        vm.prank(BORROWER);
        vault2.ackLoanReceived();
        
        // Build full price history for vault2
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault2.updatePrice();
        }
        
        // Keep history fresh but set oracle price just over MAX_PRICE_AGE
        vm.warp(block.timestamp + 1 minutes);
        vault2.updatePrice();
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp - 5 minutes - 1);
        
        // Should fail with stale oracle price when requesting liquidation
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault2.requestLiquidation();
    }
    
    function testRegressionRingBufferWrapAround() public {
        // Test ring buffer pointer wrap from 1439 → 0
        
        // Fill buffer completely (1440 entries)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            vault.updatePrice();
        }
        
        // priceHistoryIndex should be at 0 (wrapped around)
        // Add one more update to test wrap-around behavior
        vm.warp(block.timestamp + 1 minutes);
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 5000000000, 1000000, -8, block.timestamp);
        vault.updatePrice();
        
        // Verify the oldest entry was overwritten
        assertEq(vault.getPriceHistoryLength(), 1440); // Still 1440, not growing
        
        // The first slot (index 0) should now have the newest timestamp
        (uint192 price, uint64 timestamp) = vault.priceHistory(0);
        assertEq(uint256(price), 50e18); // New price
        assertEq(timestamp, block.timestamp); // Latest timestamp
    }
    
    function testRegressionExact50PercentThreshold() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Test exactly 50% drop (should succeed)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            // Exactly 50% of initial price (100e18 * 0.5 = 50e18)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 5000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Request liquidation (liquidation price is $50, current price is exactly $50)
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
    }
    
    function testRegressionPriceDropRounding() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Test price above liquidation threshold (should fail)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            // Price above liquidation price ($50.01 > $50)
            // In Pyth format with expo -8: 5001000000
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 5001000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.PriceDropThresholdNotMet.selector);
        vault.requestLiquidation();
        
        // Test price below liquidation threshold (should succeed)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            // Price below liquidation price ($49.99 < $50)
            // In Pyth format: 4999000000
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4999000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Request liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
    }
    
    function testRegressionPriceFreshnessExactBoundary() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Test: At exactly 1 hour (price freshness window) - should succeed
        vm.warp(block.timestamp + 1 hours);
        
        // Update oracle price to make it fresh (since getTWAPPrice checks oracle staleness)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
        
        // Request liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + 2 * TOTAL_TOKEN_AMOUNT); // Vault has double from setUp + test
    }
    
    function testRegressionPriceFreshnessJustOverBoundary() public {
        // Create new vault for testing stale price history
        CustodialVault vault2 = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        vm.prank(BORROWER);
        vault2.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        vm.prank(BORROWER);
        vault2.ackLoanReceived();
        
        // Build full price history for vault2
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault2.updatePrice();
        }
        
        // Wait just over 1 hour (price freshness window)
        vm.warp(block.timestamp + 1 hours + 1);
        
        // Should fail with stale price history when requesting liquidation
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vm.prank(LENDER);
        vault2.requestLiquidation();
    }

    function testZeroPriceRejected() public {
        // Set zero price in mock
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 0, 1000000, -8, block.timestamp);
        
        // Try to update price - should fail
        vm.warp(block.timestamp + 2 minutes);
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.updatePrice();
    }

    function testLenderWithdrawStalePriceHistory() public {
        // Vault already has tokens from setUp

        // Build full 24 hours of price history at 40% price
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Wait more than 1 hour without updating (price freshness window)
        vm.warp(block.timestamp + 1 hours + 1);

        // Try to request liquidation - should fail due to stale price history
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault.requestLiquidation();
        
        // Update price to make it fresh - first update the mock oracle price
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
        vault.updatePrice();
        
        // Now liquidation request should succeed
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window and then withdraw
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
    }


    function testLenderWithdrawWithNegativePrice() public {
        // Vault already has tokens from setUp

        // Build full price history first
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Now set negative price (which will cause InvalidAmount when converting)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), -5000000000, 1000000, -8, block.timestamp);

        // Try to request liquidation - should fail when getting TWAP due to negative current price
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.requestLiquidation();
    }

    function testBorrowerWithdrawsAllFunds() public {
        // Create new vault to test withdrawal after 3 days without start
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Deposit initial amount
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();

        // Send additional funds
        uint256 additionalFunds = 5 ether;
        payable(address(newVault)).transfer(additionalFunds);

        // Fast forward past 3 days
        vm.warp(block.timestamp + 3 days + 1);

        uint256 recipientBalanceBefore = RECIPIENT.balance;
        uint256 totalVaultBalance = address(newVault).balance;

        // Foundation withdraws after 3 days without ackLoanReceived() - should get ALL funds
        vm.prank(BORROWER);
        newVault.withdrawByBorrower(RECIPIENT);

        // Verify recipient received ALL funds
        assertEq(RECIPIENT.balance, recipientBalanceBefore + totalVaultBalance);
        assertEq(address(newVault).balance, 0);
    }

    function testLenderWithdrawsAllFunds() public {
        // Send initial amount
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Send additional funds
        uint256 additionalFunds = 5 ether;
        payable(address(vault)).transfer(additionalFunds);

        // Build full 24 hours of price history at 40% price (60% drop)
        for (uint256 i = 0; i < 1440; i++) { // 24 hours = 1440 minutes
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            
            // Update price every minute to fill ring buffer
            vault.updatePrice();
        }

        // Request liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation time window
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 lenderBalanceBefore = LENDER.balance;
        uint256 totalVaultBalance = address(vault).balance;

        // Lender withdraws
        vm.prank(LENDER);
        vault.withdrawByLender();

        // Verify lender received ALL funds
        assertEq(LENDER.balance, lenderBalanceBefore + totalVaultBalance);
        assertEq(address(vault).balance, 0);
    }


    function testLenderWithdrawAfterLockEndNoPriceData() public {
        // Vault already has tokens from setUp

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        // Lender should be able to withdraw even without any price data
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
        assertTrue(vault.withdrawn());
    }

    function testLenderWithdrawAfterLockEndWithHighPrice() public {
        // Vault already has tokens from setUp

        // Set price higher than initial (price increase scenario)
        int64 pythPrice = 15000000000; // 150% of initial price
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
        vault.updatePrice();

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        // Lender should be able to withdraw regardless of price
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
        assertTrue(vault.withdrawn());
    }

    function testLenderVsFoundationPriority() public {
        // Vault already has tokens from setUp

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Foundation cannot withdraw after ackLoanReceived()
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        vault.withdrawByBorrower(RECIPIENT);

        // But lender can still withdraw without approval
        uint256 lenderBalanceBefore = LENDER.balance;
        
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
        assertTrue(vault.withdrawn());

        // Foundation cannot withdraw after lender already withdrew
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.withdrawByBorrower(RECIPIENT);
    }

    function testLenderWithdrawAfterLockEndWithStalePrice() public {
        // Vault already has tokens from setUp

        // Build some price history
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 10000000000; // Normal price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Fast forward past lock period (price becomes stale)
        vm.warp(vault.lockEndTime() + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        // Lender should be able to withdraw even with stale price
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT); // Vault only has tokens from setUp
        assertTrue(vault.withdrawn());
    }

    function testPriceHistoryChronologicalOrder() public {
        // This test verifies that price entries are stored in chronological order
        // The contract enforces this by using block.timestamp when storing prices
        // Vault already has tokens from setUp

        // Build valid price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Prices are always stored with block.timestamp, ensuring chronological order
        // The validation will pass during liquidation request
        vm.prank(LENDER);
        vault.requestLiquidation();
        assertTrue(vault.liquidationRequestActive());
        
        // Wait for liquidation window and then withdraw
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testInvalidPriceHistoryTooInfrequent() public {
        // Vault already has tokens from setUp

        // Build price history with updates too infrequent (every 2 minutes)
        for (uint256 i = 0; i < 720; i++) { // Only 720 updates in 24 hours
            vm.warp(block.timestamp + 2 minutes); // Too infrequent
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Try to request liquidation - should fail due to insufficient price history
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InsufficientPriceHistory.selector);
        vault.requestLiquidation();
    }

    function testValidPriceHistoryExactlyOneMinute() public {
        // Vault already has tokens from setUp

        // Build perfect price history with exactly 1 minute intervals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Should be able to request liquidation with valid price history
        vm.prank(LENDER);
        vault.requestLiquidation();
        assertTrue(vault.liquidationRequestActive());
        
        // Wait for liquidation window and then withdraw
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testValidPriceHistoryFullDay() public {
        // Vault already has tokens from setUp

        // Build price history for full 24 hours
        for (uint256 i = 0; i < 1440; i++) { // 24 hours = 1440 minutes
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Should be able to request liquidation with full 24 hours of data
        vm.prank(LENDER);
        vault.requestLiquidation();
        assertTrue(vault.liquidationRequestActive());
        
        // Wait for liquidation window and then withdraw
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testPriceHistoryValidationOnlyBeforeLockEnd() public {
        // Vault already has tokens from setUp

        // Build invalid price history (too infrequent)
        for (uint256 i = 0; i < 720; i++) {
            vm.warp(block.timestamp + 2 minutes); // Too infrequent
            int64 pythPrice = 4000000000; // 40% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Should be able to withdraw after lock end even with invalid history
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testUpdateHistoricalPrices() public {
        // Vault already has tokens from setUp

        // Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours);

        // Prepare timestamps for last 24 hours (every hour)
        uint64[] memory timestamps = new uint64[](24);
        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < 24; i++) {
            timestamps[i] = uint64(currentTime - (24 - i) * 1 hours);
        }

        // Set different prices for testing
        int64 pythPrice = 4000000000; // 40% of initial price
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);

        // Prepare update data (mock)
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        // Calculate fee
        uint256 fee = 0.001 ether * timestamps.length;

        // Update historical prices
        vault.updateHistoricalPrices{value: fee}(updateData, timestamps);

        // Verify price history was updated
        assertEq(vault.priceHistoryLength(), 24);
        assertEq(vault.lastPriceUpdate(), timestamps[23]);
    }

    function testUpdateHistoricalPricesInvalidTimestamps() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Fast forward to ensure we have enough time to subtract from
        vm.warp(block.timestamp + 3 hours);

        // Test with timestamps out of order
        uint64[] memory timestamps = new uint64[](2);
        timestamps[0] = uint64(block.timestamp - 1 hours);
        timestamps[1] = uint64(block.timestamp - 2 hours); // Wrong order

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(CustodialVault.InvalidPriceHistory.selector);
        vault.updateHistoricalPrices{value: 0.002 ether}(updateData, timestamps);
    }

    function testUpdateHistoricalPricesTooOld() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Fast forward to ensure we have enough time to subtract from
        vm.warp(block.timestamp + 26 hours);

        // Test with timestamp older than 24 hours
        uint64[] memory timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp - 25 hours);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(CustodialVault.TimestampOutOfRange.selector);
        vault.updateHistoricalPrices{value: 0.001 ether}(updateData, timestamps);
    }

    function testUpdateHistoricalPricesFuture() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Test with future timestamp
        uint64[] memory timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp + 1 hours);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(CustodialVault.TimestampOutOfRange.selector);
        vault.updateHistoricalPrices{value: 0.001 ether}(updateData, timestamps);
    }

    function testWithdrawAfterHistoricalUpdate() public {
        // Vault already has tokens from setUp

        // Fast forward 24 hours
        vm.warp(block.timestamp + 24 hours);

        // Prepare timestamps for last 24 hours (every minute for full coverage)
        uint64[] memory timestamps = new uint64[](1440);
        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < 1440; i++) {
            timestamps[i] = uint64(currentTime - (1440 - i) * 60);
        }

        // Set low price for withdrawal
        int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);

        // Prepare update data
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        // Update historical prices
        uint256 fee = 0.001 ether * timestamps.length;
        vault.updateHistoricalPrices{value: fee}(updateData, timestamps);

        // Update current price
        vault.updatePrice();

        // Now should be able to request liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation window
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Now should be able to withdraw
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testUpdateHistoricalPricesRefund() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Fast forward to ensure we have enough time to subtract from
        vm.warp(block.timestamp + 2 hours);

        uint64[] memory timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp - 1 hours);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        uint256 balanceBefore = address(this).balance;
        
        // Send excess fee
        vault.updateHistoricalPrices{value: 0.01 ether}(updateData, timestamps);
        
        // Should receive refund (sent 0.01 ether, used 0.001 ether, so should get 0.009 ether back)
        assertGe(address(this).balance, balanceBefore - 0.001 ether);
    }

    function testUpdateHistoricalPricesEmptyData() public {
        // Test with empty pythUpdateData
        bytes[] memory emptyUpdateData = new bytes[](0);
        uint64[] memory timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp);
        
        vm.expectRevert(CustodialVault.EmptyPriceUpdateData.selector);
        vault.updateHistoricalPrices{value: 0.01 ether}(emptyUpdateData, timestamps);
        
        // Test with empty timestamps
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        uint64[] memory emptyTimestamps = new uint64[](0);
        
        vm.expectRevert(CustodialVault.EmptyPriceUpdateData.selector);
        vault.updateHistoricalPrices{value: 0.01 ether}(updateData, emptyTimestamps);
    }

    function testUpdateHistoricalPricesTooManyUpdates() public {
        // Try to update more than MAX_PRICE_POINTS (1440) at once
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        
        uint64[] memory timestamps = new uint64[](1441); // One more than allowed
        for (uint256 i = 0; i < 1441; i++) {
            timestamps[i] = uint64(block.timestamp + i * 60); // 1 minute intervals
        }
        
        vm.expectRevert(CustodialVault.TooManyPriceUpdates.selector);
        vault.updateHistoricalPrices{value: 1 ether}(updateData, timestamps);
    }

    function testProposeLiquidationPrice() public {
        uint256 newLiquidationPrice = 30e18; // $30
        
        // Only borrower can propose
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.proposeLiquidationPrice(newLiquidationPrice);
        
        // Foundation proposes new liquidation price
        vm.prank(BORROWER);
        vault.proposeLiquidationPrice(newLiquidationPrice);
        
        assertEq(vault.proposedLiquidationPrice(), newLiquidationPrice);
        assertTrue(vault.liquidationPriceProposalActive());
    }

    function testProposeLiquidationPriceInvalidAmount() public {
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.proposeLiquidationPrice(0);
    }

    function testProposeLiquidationPriceAlreadyActive() public {
        uint256 firstPrice = 30e18;
        uint256 secondPrice = 40e18;
        
        // First proposal
        vm.prank(BORROWER);
        vault.proposeLiquidationPrice(firstPrice);
        
        // Second proposal should fail
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.ProposalAlreadyActive.selector);
        vault.proposeLiquidationPrice(secondPrice);
    }

    function testApproveLiquidationPrice() public {
        uint256 newPrice = 30e18;
        
        // Foundation proposes
        vm.prank(BORROWER);
        vault.proposeLiquidationPrice(newPrice);
        
        // Only lender can approve
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.approveLiquidationPrice();
        
        // Lender approves
        vm.prank(LENDER);
        vault.approveLiquidationPrice();
        
        // Check state
        assertEq(vault.liquidationPrice(), newPrice);
        assertEq(vault.proposedLiquidationPrice(), 0);
        assertFalse(vault.liquidationPriceProposalActive());
    }

    function testApproveLiquidationPriceNoProposal() public {
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NoActiveProposal.selector);
        vault.approveLiquidationPrice();
    }

    function testRejectLiquidationPrice() public {
        uint256 oldPrice = vault.liquidationPrice();
        uint256 proposedPrice = 30e18;
        
        // Foundation proposes
        vm.prank(BORROWER);
        vault.proposeLiquidationPrice(proposedPrice);
        
        // Only lender can reject
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.rejectLiquidationPrice();
        
        // Lender rejects
        vm.prank(LENDER);
        vault.rejectLiquidationPrice();
        
        // Check state - price should remain unchanged
        assertEq(vault.liquidationPrice(), oldPrice);
        assertEq(vault.proposedLiquidationPrice(), 0);
        assertFalse(vault.liquidationPriceProposalActive());
    }

    function testRejectLiquidationPriceNoProposal() public {
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NoActiveProposal.selector);
        vault.rejectLiquidationPrice();
    }

    function testLiquidationPriceUpdateFlow() public {
        // Vault is already started with initial liquidation price of $50 from setUp
        
        // Foundation proposes to lower liquidation price to $30
        uint256 newPrice = 30e18;
        vm.prank(BORROWER);
        vault.proposeLiquidationPrice(newPrice);
        
        // Lender approves
        vm.prank(LENDER);
        vault.approveLiquidationPrice();
        
        // Set up price history and current price at $25 (below new liquidation price of $30)
        // Convert $25 to Pyth price format: 25 * 1e8 = 2500000000
        int64 pythPrice = 2500000000; // $25 with 8 decimals
        
        // Build full price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Lender requests liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for liquidation time window
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Now lender can withdraw
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertTrue(vault.withdrawn());
    }

    function testRequestLiquidation() public {
        // Build full price history below liquidation price
        int64 pythPrice = 4000000000; // $40 with 8 decimals (below $50 liquidation price)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Only lender can request liquidation
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.requestLiquidation();
        
        // Lender requests liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        assertTrue(vault.liquidationRequestActive());
        assertEq(vault.liquidationRequestTime(), block.timestamp);
    }

    function testRequestLiquidationPriceNotMet() public {
        // Build full price history above liquidation price
        int64 pythPrice = 6000000000; // $60 with 8 decimals (above $50 liquidation price)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Should fail - price not below liquidation price
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.PriceDropThresholdNotMet.selector);
        vault.requestLiquidation();
    }

    function testRequestLiquidationAlreadyActive() public {
        // Build full price history below liquidation price
        int64 pythPrice = 4000000000; // $40 with 8 decimals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // First request
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Second request should fail
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.LiquidationRequestAlreadyActive.selector);
        vault.requestLiquidation();
    }

    function testCancelLiquidationRequest() public {
        // Build full price history and request liquidation
        int64 pythPrice = 4000000000; // $40 with 8 decimals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Only lender can cancel
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.cancelLiquidationRequest();
        
        // Lender cancels
        vm.prank(LENDER);
        vault.cancelLiquidationRequest();
        
        assertFalse(vault.liquidationRequestActive());
        assertEq(vault.liquidationRequestTime(), 0);
    }

    function testWithdrawBeforeLiquidationWindow() public {
        // Build full price history and request liquidation
        int64 pythPrice = 4000000000; // $40 with 8 decimals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Try to withdraw before 24 hours
        vm.warp(block.timestamp + 23 hours);
        
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.LiquidationTimeWindowNotPassed.selector);
        vault.withdrawByLender();
    }

    function testWithdrawAfterLiquidationWindow() public {
        // Build full price history and request liquidation
        int64 pythPrice = 4000000000; // $40 with 8 decimals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // Wait for full 24 hours
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Should succeed
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertTrue(vault.withdrawn());
    }

    function testLiquidationCancelledOnPriceUpdate() public {
        // Build full price history and request liquidation
        int64 pythPrice = 4000000000; // $40 with 8 decimals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vault.requestLiquidation();
        assertTrue(vault.liquidationRequestActive());
        
        // Foundation proposes new liquidation price
        vm.prank(BORROWER);
        vault.proposeLiquidationPrice(30e18);
        
        // Lender approves - this should cancel the liquidation request
        vm.prank(LENDER);
        vault.approveLiquidationPrice();
        
        // Liquidation request should be cancelled
        assertFalse(vault.liquidationRequestActive());
        assertEq(vault.liquidationRequestTime(), 0);
    }

    function testWithdrawWithoutLiquidationRequest() public {
        // Try to withdraw without liquidation request
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NoActiveLiquidationRequest.selector);
        vault.withdrawByLender();
    }

    function testLenderCannotWithdrawIfNotStarted() public {
        // Create a new vault that hasn't been started
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Fund the vault
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Try to withdraw without starting - should fail
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotStarted.selector);
        newVault.withdrawByLender();
    }

    function testLenderCannotRequestLiquidationIfNotStarted() public {
        // Create a new vault that hasn't been started
        CustodialVault newVault = new CustodialVault(
            BORROWER,
            LENDER,
            LIQUIDATION_PRICE,
            TOTAL_TOKEN_AMOUNT
        );
        
        // Fund the vault
        vm.prank(BORROWER);
        newVault.depositCollateral{value: TOTAL_TOKEN_AMOUNT}();
        
        // Try to request liquidation without starting - should fail
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotStarted.selector);
        newVault.requestLiquidation();
    }

    function testLenderWithdrawFlowAfterLockEnd() public {
        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);
        
        // Lender should be able to withdraw directly without liquidation request
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertTrue(vault.withdrawn());
    }

    function testLenderCannotRequestLiquidationAfterLockEnd() public {
        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);
        
        // Try to request liquidation - should fail
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.WithdrawalNotAllowed.selector);
        vault.requestLiquidation();
    }

    function testCompleteWithdrawalFlow() public {
        // 1. Vault is started (from setUp)
        assertTrue(vault.started());
        
        // 2. Build price history below liquidation price
        int64 pythPrice = 4000000000; // $40 (below $50 liquidation)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // 3. Request liquidation
        vm.prank(LENDER);
        vault.requestLiquidation();
        
        // 4. Cannot withdraw immediately
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.LiquidationTimeWindowNotPassed.selector);
        vault.withdrawByLender();
        
        // 5. Wait 24 hours
        vm.warp(block.timestamp + 24 hours + 1);
        
        // 6. Now can withdraw
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertTrue(vault.withdrawn());
    }

    // Emergency Withdrawal Tests
    
    function testProposeEmergencyWithdrawal() public {
        address emergencyRecipient = address(0x999);
        
        // Only borrower can propose
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Foundation proposes
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        assertEq(vault.proposedEmergencyRecipient(), emergencyRecipient);
        assertTrue(vault.emergencyWithdrawalProposed());
        assertFalse(vault.emergencyWithdrawalApproved());
    }

    function testProposeEmergencyWithdrawalInvalidRecipient() public {
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        vault.proposeEmergencyWithdrawal(address(0));
    }

    function testApproveEmergencyWithdrawal() public {
        address emergencyRecipient = address(0x999);
        
        // First propose
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Only lender can approve
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.approveEmergencyWithdrawal();
        
        // Lender approves
        vm.prank(LENDER);
        vault.approveEmergencyWithdrawal();
        
        assertTrue(vault.emergencyWithdrawalApproved());
    }

    function testApproveEmergencyWithdrawalNoProposal() public {
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NoEmergencyWithdrawalProposed.selector);
        vault.approveEmergencyWithdrawal();
    }

    function testExecuteEmergencyWithdrawal() public {
        address emergencyRecipient = address(0x999);
        uint256 vaultBalance = address(vault).balance;
        
        // Propose
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Approve
        vm.prank(LENDER);
        vault.approveEmergencyWithdrawal();
        
        // Execute
        uint256 recipientBalanceBefore = emergencyRecipient.balance;
        vm.prank(BORROWER);
        vault.executeEmergencyWithdrawal();
        
        // Verify
        assertEq(emergencyRecipient.balance, recipientBalanceBefore + vaultBalance);
        assertEq(address(vault).balance, 0);
        assertTrue(vault.withdrawn());
        assertEq(vault.proposedEmergencyRecipient(), address(0));
        assertFalse(vault.emergencyWithdrawalProposed());
        assertFalse(vault.emergencyWithdrawalApproved());
    }

    function testExecuteEmergencyWithdrawalNotApproved() public {
        address emergencyRecipient = address(0x999);
        
        // Propose but don't approve
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Try to execute
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.EmergencyWithdrawalNotApproved.selector);
        vault.executeEmergencyWithdrawal();
    }

    function testExecuteEmergencyWithdrawalNoProposal() public {
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.NoEmergencyWithdrawalProposed.selector);
        vault.executeEmergencyWithdrawal();
    }

    function testExecuteEmergencyWithdrawalNotAuthorized() public {
        address emergencyRecipient = address(0x999);
        
        // Propose and approve
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        vm.prank(LENDER);
        vault.approveEmergencyWithdrawal();
        
        // Try to execute as non-borrower
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.executeEmergencyWithdrawal();
    }

    function testCancelEmergencyWithdrawalByFoundation() public {
        address emergencyRecipient = address(0x999);
        
        // Propose
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Cancel by borrower
        vm.prank(BORROWER);
        vault.cancelEmergencyWithdrawal();
        
        assertEq(vault.proposedEmergencyRecipient(), address(0));
        assertFalse(vault.emergencyWithdrawalProposed());
        assertFalse(vault.emergencyWithdrawalApproved());
    }

    function testCancelEmergencyWithdrawalByLender() public {
        address emergencyRecipient = address(0x999);
        
        // Propose
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Cancel by lender
        vm.prank(LENDER);
        vault.cancelEmergencyWithdrawal();
        
        assertEq(vault.proposedEmergencyRecipient(), address(0));
        assertFalse(vault.emergencyWithdrawalProposed());
        assertFalse(vault.emergencyWithdrawalApproved());
    }

    function testCancelEmergencyWithdrawalNotAuthorized() public {
        address emergencyRecipient = address(0x999);
        
        // Propose
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        // Try to cancel as unauthorized user
        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.cancelEmergencyWithdrawal();
    }

    function testEmergencyWithdrawalCancelsLiquidationRequest() public {
        // First, set up a liquidation request
        int64 pythPrice = 4000000000; // $40
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vault.requestLiquidation();
        assertTrue(vault.liquidationRequestActive());
        
        // Now do emergency withdrawal
        address emergencyRecipient = address(0x999);
        vm.prank(BORROWER);
        vault.proposeEmergencyWithdrawal(emergencyRecipient);
        
        vm.prank(LENDER);
        vault.approveEmergencyWithdrawal();
        
        vm.prank(BORROWER);
        vault.executeEmergencyWithdrawal();
        
        // Liquidation request should be cancelled
        assertFalse(vault.liquidationRequestActive());
        assertEq(vault.liquidationRequestTime(), 0);
    }

    function testEmergencyWithdrawalAfterWithdrawn() public {
        // First withdraw normally
        vm.warp(vault.lockEndTime() + 1);
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        // Try to propose emergency withdrawal
        vm.prank(BORROWER);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.proposeEmergencyWithdrawal(address(0x999));
    }

    function testConfidenceIntervalValidation() public {
        // Test that prices with high confidence intervals are rejected
        
        // Check initial state - should have no price history
        uint256 initialLength = vault.getPriceHistoryLength();
        assertEq(initialLength, 0);
        
        // Warp time to ensure we can update (needs to be at least 1 minute from lastPriceUpdate which is 0)
        vm.warp(block.timestamp + 1 minutes);
        
        // First set a price with normal confidence (1% of price)
        int64 normalPrice = 10000000000; // $100
        uint64 normalConfidence = 100000000; // $1 confidence (1%)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), normalPrice, normalConfidence, -8, block.timestamp);
        
        // This should update successfully
        vault.updatePrice();
        assertEq(vault.getPriceHistoryLength(), 1);
        
        // Now try to update with high confidence interval (5% of price)
        vm.warp(block.timestamp + 1 minutes);
        int64 highConfPrice = 10000000000; // $100
        uint64 highConfidence = 500000000; // $5 confidence (5% - exceeds 3% threshold)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), highConfPrice, highConfidence, -8, block.timestamp);
        
        // This should not update due to high confidence
        vault.updatePrice();
        assertEq(vault.getPriceHistoryLength(), 1); // Should still be 1, not updated
        
        // Test updateHistoricalPrices with high confidence
        bytes[] memory pythUpdateData = new bytes[](1);
        pythUpdateData[0] = hex"01"; // Mock update data
        uint64[] memory timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp - 30);
        
        // Set high confidence price for parsePriceFeedUpdates
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), highConfPrice, highConfidence, -8, timestamps[0]);
        
        // This should revert with ExcessiveConfidenceInterval
        vm.expectRevert(CustodialVault.ExcessiveConfidenceInterval.selector);
        vault.updateHistoricalPrices{value: 0.01 ether}(pythUpdateData, timestamps);
    }

    function testConfidenceIntervalEdgeCase() public {
        // Check initial state
        assertEq(vault.getPriceHistoryLength(), 0);
        
        // Warp time to ensure we can update
        vm.warp(block.timestamp + 1 minutes);
        
        // Test exactly at 3% confidence threshold
        int64 price = 10000000000; // $100
        uint64 confidence = 300000000; // $3 confidence (exactly 3%)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), price, confidence, -8, block.timestamp);
        
        // This should update successfully (at threshold)
        vault.updatePrice();
        assertEq(vault.getPriceHistoryLength(), 1);
        
        // Test just above threshold (3.01%)
        vm.warp(block.timestamp + 1 minutes);
        confidence = 301000000; // $3.01 confidence (3.01%)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), price, confidence, -8, block.timestamp);
        
        // This should not update
        vault.updatePrice();
        assertEq(vault.getPriceHistoryLength(), 1); // Should still be 1
    }
}