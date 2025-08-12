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
    
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64
    ) external payable override returns (IPyth.Price[] memory priceFeeds) {
        priceFeeds = new IPyth.Price[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            if (priceSet[priceIds[i]]) {
                // Return the stored price if it matches the time range
                if (prices[priceIds[i]].publishTime >= minPublishTime) {
                    priceFeeds[i] = prices[priceIds[i]];
                } else {
                    // Return a price with the requested timestamp
                    priceFeeds[i] = IPyth.Price(
                        prices[priceIds[i]].price,
                        prices[priceIds[i]].conf,
                        prices[priceIds[i]].expo,
                        minPublishTime + 30 // Middle of the time range
                    );
                }
            } else {
                // Return default price with requested timestamp
                priceFeeds[i] = IPyth.Price(10000000000, 1000000, -8, minPublishTime + 30);
            }
        }
        return priceFeeds;
    }
}

contract CustodialVaultTest is Test {
    CustodialVault public vault;
    MockPyth public mockPyth;
    
    // Add receive function to accept refunds
    receive() external payable {}

    address constant FOUNDATION = address(0x1);
    address constant LENDER = address(0x2);
    address constant OTHER_USER = address(0x3);
    address constant RECIPIENT = address(0x4);
    // vault.IP_PRICE_FEED_ID() is now hardcoded in CustodialVault contract
    // bytes32: 0xb620ba83044577029da7e4ded7a2abccf8e6afc2a0d4d26d89ccdd39ec109025

    uint256 constant INITIAL_PRICE = 100e18; // $100 with 18 decimals
    uint256 constant TOTAL_TOKEN_AMOUNT = 10 ether;
    uint256 constant LOCK_DURATION = 30 days; // 1 month for testing

    event TokensWithdrawnByFoundation(address indexed foundation, address indexed recipient, uint256 amount);
    event TokensWithdrawnByLender(address indexed lender, uint256 amount, uint256 currentPrice);
    event LenderApprovalGranted(address indexed lender);
    event PriceUpdated(uint256 price, uint256 timestamp);
    event ThresholdIncreaseProposed(uint256 proposedThreshold, address indexed proposer);
    event ThresholdIncreaseApproved(uint256 newThreshold, address indexed approver);
    event ThresholdIncreaseRejected(address indexed rejector);

    function setUp() public {
        // Deploy mock Pyth oracle at the expected address (Aeneid testnet)
        mockPyth = MockPyth(address(0x36825bf3Fbdf5a29E2d5148bfe7Dcf7B5639e320));
        vm.etch(address(mockPyth), type(MockPyth).runtimeCode);

        // Deploy CustodialVault with lock end time in the future
        uint256 lockEndTime = block.timestamp + LOCK_DURATION;
        vault = new CustodialVault(
            FOUNDATION,
            LENDER,
            INITIAL_PRICE,
            TOTAL_TOKEN_AMOUNT,
            lockEndTime
        );

        // Fund test accounts
        vm.deal(FOUNDATION, 100 ether);
        vm.deal(LENDER, 100 ether);
        vm.deal(OTHER_USER, 100 ether);
    }

    function testReceiveFunds() public {
        // Test that vault can receive funds
        uint256 sendAmount = TOTAL_TOKEN_AMOUNT;
        payable(address(vault)).transfer(sendAmount);
        assertEq(address(vault).balance, sendAmount);
    }

    function testConstructorValidation() public {
        uint256 futureTime = block.timestamp + 1 days;

        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        new CustodialVault(address(0), LENDER, INITIAL_PRICE, TOTAL_TOKEN_AMOUNT, futureTime);

        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        new CustodialVault(FOUNDATION, address(0), INITIAL_PRICE, TOTAL_TOKEN_AMOUNT, futureTime);

        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        new CustodialVault(FOUNDATION, LENDER, 0, TOTAL_TOKEN_AMOUNT, futureTime);

        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        new CustodialVault(FOUNDATION, LENDER, INITIAL_PRICE, 0, futureTime);

        vm.expectRevert(CustodialVault.InvalidTime.selector);
        new CustodialVault(FOUNDATION, LENDER, INITIAL_PRICE, TOTAL_TOKEN_AMOUNT, block.timestamp);
    }

    function testWithdrawByFoundationAfterLockWithApproval() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Lender approves withdrawal
        vm.prank(LENDER);
        vm.expectEmit(true, true, true, true);
        emit LenderApprovalGranted(LENDER);
        vault.approveFoundationWithdrawal();

        uint256 recipientBalanceBefore = RECIPIENT.balance;

        // Foundation withdraws to recipient
        vm.prank(FOUNDATION);
        vm.expectEmit(true, true, true, true);
        emit TokensWithdrawnByFoundation(FOUNDATION, RECIPIENT, TOTAL_TOKEN_AMOUNT);
        vault.withdrawByFoundation(RECIPIENT);

        assertEq(RECIPIENT.balance, recipientBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertEq(address(vault).balance, 0);

        (,,,bool isWithdrawn,,) = vault.getVaultDetails();
        assertEq(isWithdrawn, true);
    }

    function testWithdrawByFoundationBeforeLockPeriod() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Try to withdraw before lock period
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.LockPeriodNotExpired.selector);
        vault.withdrawByFoundation(RECIPIENT);
    }

    function testWithdrawByFoundationWithoutLenderApproval() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Try to withdraw without lender approval
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.LenderApprovalRequired.selector);
        vault.withdrawByFoundation(RECIPIENT);
    }

    function testWithdrawByFoundationNotAuthorized() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Try to withdraw as different user
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.withdrawByFoundation(RECIPIENT);
    }

    function testWithdrawByFoundationInvalidRecipient() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Lender approves
        vm.prank(LENDER);
        vault.approveFoundationWithdrawal();

        // Try to withdraw to zero address
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.InvalidAddress.selector);
        vault.withdrawByFoundation(address(0));
    }

    function testLenderApprovalBeforeLockEnd() public {
        // Try to approve before lock period ends
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.LockPeriodNotExpired.selector);
        vault.approveFoundationWithdrawal();
    }

    function testLenderApprovalNotAuthorized() public {
        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Try to approve as different user
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.approveFoundationWithdrawal();
    }

    function testWithdrawByLenderOnPriceDrop() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build full 24 hours of price history at 40% price (60% drop)
        for (uint256 i = 0; i < 1440; i++) { // 24 hours = 1440 minutes
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            
            // Update price every minute to fill ring buffer
            vault.updatePrice();
        }

        uint256 lenderBalanceBefore = LENDER.balance;

        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertEq(address(vault).balance, 0);

        (,,,bool isWithdrawn,,) = vault.getVaultDetails();
        assertEq(isWithdrawn, true);
    }

    function testWithdrawByLenderInsufficientPriceHistory() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build some price history but not enough (less than 1440 points)
        for (uint256 i = 0; i < 1000; i++) { // Only 1000 points, need 1440
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InsufficientPriceHistory.selector);
        vault.withdrawByLender();
    }

    function testWithdrawByLenderPriceDropNotMet() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build full price history with small decline (not enough for 50% drop)
        for (uint256 i = 0; i < 1440; i++) { // Full 24 hours
            vm.warp(block.timestamp + 1 minutes);
            
            // Set price to 60% of initial (40% drop, not enough)
            uint256 targetPrice = (INITIAL_PRICE * 60) / 100;
            int64 pythPrice = int64(uint64(targetPrice / 1e10));
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            
            // Update price to fill the ring buffer
            vault.updatePrice();
        }

        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.PriceDropThresholdNotMet.selector);
        vault.withdrawByLender();
    }

    function testWithdrawByLenderAfterLockEnd() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        // Lender should be able to withdraw after lock end without restrictions
        vm.prank(LENDER);
        vm.expectEmit(true, false, false, true);
        emit TokensWithdrawnByLender(LENDER, TOTAL_TOKEN_AMOUNT, 0); // price is 0 for post-lock withdrawals
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertTrue(vault.withdrawn());
    }

    function testWithdrawByLenderNotAuthorized() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.withdrawByLender();
    }

    function testDoubleWithdrawal() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Lender approves
        vm.prank(LENDER);
        vault.approveFoundationWithdrawal();

        // First withdrawal
        vm.prank(FOUNDATION);
        vault.withdrawByFoundation(RECIPIENT);

        // Try to withdraw again
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.withdrawByFoundation(RECIPIENT);
    }

    function testGetVaultDetails() public {
        (uint256 initPrice, uint256 tokenAmount, uint256 lockEnd, bool isWithdrawn, bool hasLenderApproval, uint256 currentBalance) = vault.getVaultDetails();
        assertEq(initPrice, INITIAL_PRICE);
        assertEq(tokenAmount, TOTAL_TOKEN_AMOUNT);
        assertEq(lockEnd, vault.lockEndTime());
        assertEq(isWithdrawn, false);
        assertEq(hasLenderApproval, false);
        assertEq(currentBalance, 0);

        // Send tokens
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        (,,,,,currentBalance) = vault.getVaultDetails();
        assertEq(currentBalance, TOTAL_TOKEN_AMOUNT);
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
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build full price history first (24 hours)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Keep price history fresh by updating
        vm.warp(block.timestamp + 1 minutes);
        
        // Set oracle price with old timestamp (stale oracle data)
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp - 10 minutes);

        // Try to withdraw - should fail due to stale oracle price in _getTWAPPrice
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault.withdrawByLender();
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

    function testRefreshFeedsAndUpdatePrice() public {
        // Initial price history should be empty
        assertEq(vault.getPriceHistoryLength(), 0);
        
        // Prepare mock update data
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode("mock_update_data");
        
        // Calculate required fee
        uint256 updateFee = mockPyth.getUpdateFee(updateData);
        
        // Call refreshFeedsAndUpdatePrice with exact fee
        vm.warp(block.timestamp + 2 minutes);
        vault.refreshFeedsAndUpdatePrice{value: updateFee}(updateData);
        
        // Verify price was updated
        assertEq(vault.getPriceHistoryLength(), 1);
        
        // Test with excess payment - should refund
        uint256 excessAmount = 0.1 ether;
        uint256 callerBalanceBefore = address(this).balance;
        
        vm.warp(block.timestamp + 2 minutes);
        vault.refreshFeedsAndUpdatePrice{value: updateFee + excessAmount}(updateData);
        
        // Verify refund
        assertEq(address(this).balance, callerBalanceBefore - updateFee);
        assertEq(vault.getPriceHistoryLength(), 2);
        
        // Test without update data - should just update price
        vm.warp(block.timestamp + 2 minutes);
        bytes[] memory emptyData = new bytes[](0);
        vault.refreshFeedsAndUpdatePrice(emptyData);
        
        assertEq(vault.getPriceHistoryLength(), 3);
    }

    function testRefreshFeedsAndUpdatePriceInsufficientFee() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode("mock_update_data");
        
        uint256 updateFee = mockPyth.getUpdateFee(updateData);
        
        // Try with insufficient fee
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.refreshFeedsAndUpdatePrice{value: updateFee - 1}(updateData);
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
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender(); // No parameters
        
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
    }
    
    function testRegressionStaleToFreshWorkflow() public {
        // Test: Direct withdrawal fails → refreshFeedsAndUpdatePrice → withdrawal succeeds
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Wait to make price stale
        vm.warp(block.timestamp + 3 minutes);
        
        // Direct withdrawal should fail
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault.withdrawByLender();
        
        // Refresh feeds
        bytes[] memory updateData = new bytes[](0);
        vault.refreshFeedsAndUpdatePrice(updateData);
        
        // Now withdrawal should succeed
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
    }
    
    function testRegressionRefundAndUnderpayment() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode("mock_update_data");
        uint256 updateFee = mockPyth.getUpdateFee(updateData);
        
        // Test overpayment refund
        uint256 overpayment = 0.1 ether;
        uint256 balanceBefore = address(this).balance;
        vault.refreshFeedsAndUpdatePrice{value: updateFee + overpayment}(updateData);
        assertEq(address(this).balance, balanceBefore - updateFee);
        
        // Test underpayment revert
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.refreshFeedsAndUpdatePrice{value: updateFee - 1}(updateData);
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
        vault.withdrawByLender();
        
        // Add one more point to reach exactly 1440
        vm.warp(block.timestamp + 1 minutes);
        vault.updatePrice();
        
        // Now should succeed with exactly full buffer
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
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
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        
        // Test 2: Create new vault for testing stale oracle price
        CustodialVault vault2 = new CustodialVault(
            FOUNDATION,
            LENDER,
            INITIAL_PRICE,
            TOTAL_TOKEN_AMOUNT,
            block.timestamp + LOCK_DURATION
        );
        payable(address(vault2)).transfer(TOTAL_TOKEN_AMOUNT);
        
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
        
        // Should fail with stale oracle price
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault2.withdrawByLender();
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
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
    }
    
    function testRegressionPriceDropRounding() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Test 49.99% drop (should fail due to rounding)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            // 50.01% of initial price (just above threshold)
            // initialPrice = 100e18, 50.01% = 50.01e18
            // In Pyth format with expo -8: 5001000000
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 5001000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.PriceDropThresholdNotMet.selector);
        vault.withdrawByLender();
        
        // Test 50.01% drop (should succeed)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            // 49.99% of initial price (just below threshold)
            // In Pyth format: 4999000000
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4999000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
    }
    
    function testRegressionPriceFreshnessExactBoundary() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Test 1: At exactly 2 minutes - should succeed
        vm.warp(block.timestamp + 2 minutes);
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        
        // Test 2: Create new vault for testing stale price history
        CustodialVault vault2 = new CustodialVault(
            FOUNDATION,
            LENDER,
            INITIAL_PRICE,
            TOTAL_TOKEN_AMOUNT,
            block.timestamp + LOCK_DURATION
        );
        payable(address(vault2)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full price history for vault2
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault2.updatePrice();
        }
        
        // Wait just over 2 minutes
        vm.warp(block.timestamp + 2 minutes + 1);
        
        // Should fail with stale price history
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault2.withdrawByLender();
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
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build full 24 hours of price history at 40% price
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Wait more than 2 minutes without updating
        vm.warp(block.timestamp + 3 minutes);

        // Try to withdraw - should fail due to stale price history
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.StalePrice.selector);
        vault.withdrawByLender();
        
        // Update price to make it fresh
        vault.updatePrice();
        
        // Now withdrawal should succeed
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
    }

    function testLenderWithdrawWithRefreshFeeds() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build full 24 hours of price history at 40% price
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 4000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Prepare update data to refresh feeds before withdrawal
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = abi.encode("mock_update_data");
        uint256 updateFee = mockPyth.getUpdateFee(updateData);

        // First refresh the feeds as a separate transaction
        vault.refreshFeedsAndUpdatePrice{value: updateFee}(updateData);

        // Now lender can withdraw without needing to pass update data
        uint256 lenderBalanceBefore = LENDER.balance;
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertEq(address(vault).balance, 0);
    }

    function testLenderWithdrawWithNegativePrice() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build full price history first
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), 10000000000, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Now set negative price
        mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), -5000000000, 1000000, -8, block.timestamp);

        // Try to withdraw as lender - should fail when getting current price
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.withdrawByLender();
    }

    function testFoundationWithdrawsAllFunds() public {
        // Send initial amount
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Send additional funds
        uint256 additionalFunds = 5 ether;
        payable(address(vault)).transfer(additionalFunds);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Lender approves
        vm.prank(LENDER);
        vault.approveFoundationWithdrawal();

        uint256 recipientBalanceBefore = RECIPIENT.balance;
        uint256 totalVaultBalance = address(vault).balance;

        // Foundation withdraws
        vm.prank(FOUNDATION);
        vault.withdrawByFoundation(RECIPIENT);

        // Verify recipient received ALL funds
        assertEq(RECIPIENT.balance, recipientBalanceBefore + totalVaultBalance);
        assertEq(address(vault).balance, 0);
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

        uint256 lenderBalanceBefore = LENDER.balance;
        uint256 totalVaultBalance = address(vault).balance;

        // Lender withdraws
        vm.prank(LENDER);
        vault.withdrawByLender();

        // Verify lender received ALL funds
        assertEq(LENDER.balance, lenderBalanceBefore + totalVaultBalance);
        assertEq(address(vault).balance, 0);
    }

    // Test threshold increase functionality
    function testProposeThresholdIncrease() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Check initial threshold is 50%
        assertEq(vault.priceDropThreshold(), 5000);
        
        // Foundation proposes increase to 60%
        vm.prank(FOUNDATION);
        vm.expectEmit(true, true, false, true);
        emit ThresholdIncreaseProposed(6000, FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Check proposal state
        assertEq(vault.proposedThreshold(), 6000);
        assertTrue(vault.thresholdProposalActive());
    }

    function testProposeThresholdIncreaseNotAuthorized() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Non-foundation cannot propose
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.proposeThresholdIncrease(6000);
        
        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.proposeThresholdIncrease(6000);
    }

    function testProposeThresholdIncreaseInvalidThreshold() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Cannot propose decrease
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.InvalidThreshold.selector);
        vault.proposeThresholdIncrease(4000); // Less than current 50%
        
        // Cannot propose same threshold
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.InvalidThreshold.selector);
        vault.proposeThresholdIncrease(5000); // Same as current
        
        // Cannot exceed max
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.InvalidThreshold.selector);
        vault.proposeThresholdIncrease(9001); // > 90%
    }

    function testProposeThresholdIncreaseAlreadyActive() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // First proposal
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Cannot propose another while active
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.ProposalAlreadyActive.selector);
        vault.proposeThresholdIncrease(7000);
    }

    function testApproveThresholdIncrease() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Foundation proposes
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Lender approves
        vm.prank(LENDER);
        vm.expectEmit(true, true, false, true);
        emit ThresholdIncreaseApproved(6000, LENDER);
        vault.approveThresholdIncrease();
        
        // Check new threshold is active
        assertEq(vault.priceDropThreshold(), 6000);
        assertFalse(vault.thresholdProposalActive());
        assertEq(vault.proposedThreshold(), 0);
    }

    function testApproveThresholdIncreaseNotAuthorized() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Foundation proposes
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Non-lender cannot approve
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.approveThresholdIncrease();
        
        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.approveThresholdIncrease();
    }

    function testApproveThresholdIncreaseNoActiveProposal() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Cannot approve without proposal
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NoActiveProposal.selector);
        vault.approveThresholdIncrease();
    }

    function testRejectThresholdIncrease() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Foundation proposes
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Lender rejects
        vm.prank(LENDER);
        vm.expectEmit(true, false, false, true);
        emit ThresholdIncreaseRejected(LENDER);
        vault.rejectThresholdIncrease();
        
        // Check threshold unchanged
        assertEq(vault.priceDropThreshold(), 5000);
        assertFalse(vault.thresholdProposalActive());
        assertEq(vault.proposedThreshold(), 0);
    }

    function testRejectThresholdIncreaseNotAuthorized() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Foundation proposes
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Non-lender cannot reject
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.rejectThresholdIncrease();
        
        vm.prank(OTHER_USER);
        vm.expectRevert(CustodialVault.NotAuthorized.selector);
        vault.rejectThresholdIncrease();
    }

    function testRejectThresholdIncreaseNoActiveProposal() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Cannot reject without proposal
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.NoActiveProposal.selector);
        vault.rejectThresholdIncrease();
    }

    function testWithdrawalWithIncreasedThreshold() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Foundation proposes increase to 60%
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Lender approves
        vm.prank(LENDER);
        vault.approveThresholdIncrease();
        
        // Build 24 hours of price history at 45% of initial (55% drop)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4500000000; // 45% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Should not be able to withdraw at 55% drop (need 60%)
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.PriceDropThresholdNotMet.selector);
        vault.withdrawByLender();
        
        // Build 24 hours of price history at 39% of initial (61% drop)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 3900000000; // 39% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Now should be able to withdraw
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        assertTrue(vault.withdrawn());
    }

    function testCannotProposeThresholdAfterWithdrawn() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Build full 24 hours of price history at 40% price (60% drop)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Lender withdraws
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        // Cannot propose after withdrawal
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.proposeThresholdIncrease(6000);
    }

    function testCannotApproveThresholdAfterWithdrawn() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // Foundation proposes
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        // Build full 24 hours of price history at 40% price (60% drop)
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }
        
        // Lender withdraws
        vm.prank(LENDER);
        vault.withdrawByLender();
        
        // Cannot approve after withdrawal
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.approveThresholdIncrease();
    }

    function testMultipleThresholdIncreases() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);
        
        // First increase: 50% -> 60%
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(6000);
        
        vm.prank(LENDER);
        vault.approveThresholdIncrease();
        assertEq(vault.priceDropThreshold(), 6000);
        
        // Second increase: 60% -> 70%
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(7000);
        
        vm.prank(LENDER);
        vault.approveThresholdIncrease();
        assertEq(vault.priceDropThreshold(), 7000);
        
        // Third increase: 70% -> 80%
        vm.prank(FOUNDATION);
        vault.proposeThresholdIncrease(8000);
        
        vm.prank(LENDER);
        vault.approveThresholdIncrease();
        assertEq(vault.priceDropThreshold(), 8000);
    }

    function testLenderWithdrawAfterLockEndNoPriceData() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        uint256 lenderBalanceBefore = LENDER.balance;

        // Lender should be able to withdraw even without any price data
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertTrue(vault.withdrawn());
    }

    function testLenderWithdrawAfterLockEndWithHighPrice() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

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

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertTrue(vault.withdrawn());
    }

    function testLenderVsFoundationPriority() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Fast forward past lock period
        vm.warp(vault.lockEndTime() + 1);

        // Lender hasn't approved foundation withdrawal
        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.LenderApprovalRequired.selector);
        vault.withdrawByFoundation(RECIPIENT);

        // But lender can still withdraw without approval
        uint256 lenderBalanceBefore = LENDER.balance;
        
        vm.prank(LENDER);
        vault.withdrawByLender();

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertTrue(vault.withdrawn());

        // Foundation cannot withdraw after lender already withdrew
        vm.prank(LENDER);
        vault.approveFoundationWithdrawal(); // Even with approval

        vm.prank(FOUNDATION);
        vm.expectRevert(CustodialVault.AlreadyWithdrawn.selector);
        vault.withdrawByFoundation(RECIPIENT);
    }

    function testLenderWithdrawAfterLockEndWithStalePrice() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

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

        assertEq(LENDER.balance, lenderBalanceBefore + TOTAL_TOKEN_AMOUNT);
        assertTrue(vault.withdrawn());
    }

    function testPriceHistoryChronologicalOrder() public {
        // This test verifies that price entries are stored in chronological order
        // The contract enforces this by using block.timestamp when storing prices
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build valid price history
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Prices are always stored with block.timestamp, ensuring chronological order
        // The validation will pass
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testInvalidPriceHistoryTooInfrequent() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build price history with updates too infrequent (every 2 minutes)
        for (uint256 i = 0; i < 720; i++) { // Only 720 updates in 24 hours
            vm.warp(block.timestamp + 2 minutes); // Too infrequent
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Try to withdraw - should fail due to insufficient price history
        vm.prank(LENDER);
        vm.expectRevert(CustodialVault.InsufficientPriceHistory.selector);
        vault.withdrawByLender();
    }

    function testValidPriceHistoryExactlyOneMinute() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build perfect price history with exactly 1 minute intervals
        for (uint256 i = 0; i < 1440; i++) {
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Should be able to withdraw with valid price history
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testValidPriceHistoryFullDay() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Build price history for full 24 hours
        for (uint256 i = 0; i < 1440; i++) { // 24 hours = 1440 minutes
            vm.warp(block.timestamp + 1 minutes);
            int64 pythPrice = 4000000000; // 40% of initial price (60% drop)
            mockPyth.setPriceUnsafe(vault.IP_PRICE_FEED_ID(), pythPrice, 1000000, -8, block.timestamp);
            vault.updatePrice();
        }

        // Should be able to withdraw with full 24 hours of data
        vm.prank(LENDER);
        vault.withdrawByLender();
        assertTrue(vault.withdrawn());
    }

    function testPriceHistoryValidationOnlyBeforeLockEnd() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

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
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

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

        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.updateHistoricalPrices{value: 0.001 ether}(updateData, timestamps);
    }

    function testUpdateHistoricalPricesFuture() public {
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

        // Test with future timestamp
        uint64[] memory timestamps = new uint64[](1);
        timestamps[0] = uint64(block.timestamp + 1 hours);

        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";

        vm.expectRevert(CustodialVault.InvalidAmount.selector);
        vault.updateHistoricalPrices{value: 0.001 ether}(updateData, timestamps);
    }

    function testWithdrawAfterHistoricalUpdate() public {
        // Send tokens to vault
        payable(address(vault)).transfer(TOTAL_TOKEN_AMOUNT);

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
}