// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BridgeTypes} from '../../../../contracts/libraries/BridgeTypes.sol';
import {BridgeRouter} from '../../../../contracts/modules/bridge/BridgeRouter.sol';
import {Commands} from '../../../../contracts/libraries/Commands.sol';
import {Constants} from '../../../../contracts/libraries/Constants.sol';
import {IDomainRegistry} from '../../../../contracts/interfaces/external/IDomainRegistry.sol';
import {TypeCasts} from '@hyperlane/core/contracts/libs/TypeCasts.sol';
import {HypNative} from '@hyperlane/core/contracts/token/HypNative.sol';
import {HypERC20} from '@hyperlane/core/contracts/token/HypERC20.sol';
import {TestPostDispatchHook} from '@hyperlane/core/contracts/test/TestPostDispatchHook.sol';
import {LinearFee} from '@hyperlane/core/contracts/token/fees/LinearFee.sol';
import './BaseOverrideBridge.sol';

contract BridgeTokenTest is BaseOverrideBridge {
    uint256 public openUsdtBridgeAmount = USDC_1 * 1000;
    uint256 public openUsdtInitialBal = openUsdtBridgeAmount * 2;

    uint256 public xVeloBridgeAmount = TOKEN_1 * 1000;
    uint256 public xVeloInitialBal = xVeloBridgeAmount * 2;

    uint256 mockDomainId = 111;

    bytes public commands = abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)));
    bytes[] public inputs;

    /// @dev Fixed fee used for x-chain message quotes
    uint256 public constant MESSAGE_FEE = 1 ether / 10_000; // 0.0001 ETH
    uint256 leftoverETH = MESSAGE_FEE / 2;
    uint256 feeAmount = MESSAGE_FEE;

    // Bridge amounts for HypERC20Collateral tests (using deployed USDC warp route)
    uint256 public usdcBridgeAmount = 1000 * USDC_1;
    uint256 public usdcInitialBal = usdcBridgeAmount * 2;

    // HypNative (routed via HYP_ERC20_COLLATERAL sentinel with token=address(0))
    HypNative public hypNative;
    HypNative public leafHypNative;
    uint256 public nativeBridgeAmount = 0.1 ether;
    uint256 public nativeInitialBal = 10 ether;
    uint256 public leafHypNativeLiquidity = 10 ether;

    // HypERC20 synthetic (mint/burn) — routed via HYP_ERC20_COLLATERAL with token=address(hypERC20)
    HypERC20 public hypERC20;
    HypERC20 public leafHypERC20;
    uint256 public hypERC20BridgeAmount = 1 ether;
    uint256 public hypERC20InitialBal = 10 ether;

    function setUp() public override {
        super.setUp();

        deal(address(users.alice), nativeInitialBal);
        deal(OPEN_USDT_ADDRESS, users.alice, openUsdtInitialBal);
        deal(VELO_ADDRESS, users.alice, xVeloBridgeAmount);

        vm.selectFork(leafId_2);
        deal(XVELO_ADDRESS, users.alice, xVeloInitialBal);

        vm.selectFork(rootId);
        deal(VELO_ADDRESS, users.alice, xVeloInitialBal);

        // Fund alice with USDC for HypERC20Collateral tests (deployed USDC warp route on forked Optimism)
        deal(OPTIMISM_USDC_ADDRESS, users.alice, usdcInitialBal);

        // Fund USDC bridge on Base with USDC liquidity for cross-chain payouts
        vm.selectFork(leafId);
        deal(BASE_USDC_ADDRESS, USDC_BASE_BRIDGE, usdcInitialBal);
        vm.selectFork(rootId);

        // Deploy HypNative on both forks — no pre-deployed native warp route exists.
        vm.selectFork(leafId);
        vm.startPrank(users.owner);
        leafHypNative = new HypNative(1, 1, address(leafMailbox));
        leafHypNative.initialize(address(0), address(0), users.owner);
        vm.stopPrank();
        vm.deal(address(leafHypNative), leafHypNativeLiquidity); // fund for outbound payouts

        vm.selectFork(rootId);
        vm.startPrank(users.owner);
        hypNative = new HypNative(1, 1, address(rootMailbox));
        hypNative.initialize(address(0), address(0), users.owner);
        hypNative.enrollRemoteRouter(leafDomain, TypeCasts.addressToBytes32(address(leafHypNative)));
        vm.stopPrank();

        // Enroll root as remote on leaf
        vm.selectFork(leafId);
        vm.prank(users.owner);
        leafHypNative.enrollRemoteRouter(rootDomain, TypeCasts.addressToBytes32(address(hypNative)));

        // Deploy HypERC20 (synthetic mint/burn) on both forks. Initial supply on root only;
        // leaf supply is created via cross-chain mint when messages are processed.
        vm.startPrank(users.owner);
        leafHypERC20 = new HypERC20(18, 1, 1, address(leafMailbox));
        leafHypERC20.initialize(0, 'HypERC20', 'HYP', address(0), address(0), users.owner);
        vm.stopPrank();

        vm.selectFork(rootId);
        vm.startPrank(users.owner);
        hypERC20 = new HypERC20(18, 1, 1, address(rootMailbox));
        hypERC20.initialize(hypERC20InitialBal, 'HypERC20', 'HYP', address(0), address(0), users.owner);
        hypERC20.transfer(users.alice, hypERC20InitialBal);
        hypERC20.enrollRemoteRouter(leafDomain, TypeCasts.addressToBytes32(address(leafHypERC20)));
        vm.stopPrank();

        vm.selectFork(leafId);
        vm.prank(users.owner);
        leafHypERC20.enrollRemoteRouter(rootDomain, TypeCasts.addressToBytes32(address(hypERC20)));

        vm.selectFork(rootId);

        inputs = new bytes[](1);

        vm.startPrank({msgSender: users.alice});
    }

    function test_WhenRecipientIsZeroAddress() external {
        // It should revert with {InvalidRecipient}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            address(0), //recipient
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        vm.expectRevert(BridgeRouter.InvalidRecipient.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenMessageFeeIsSmallerThanContractBalance() external {
        // It should revert with {InvalidETH}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);
        vm.expectRevert(); // OutOfFunds
        router.execute{value: feeAmount - 1}(commands, inputs);
    }

    function test_RevertWhen_BridgeIsZeroAddress() external {
        // It should revert with {InvalidBridgeType}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            address(0), //bridge
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        vm.expectRevert();
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_RevertWhen_TokenIsZeroAddress() external {
        // It should revert
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            address(0),
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        vm.expectRevert();
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_RevertWhen_AmountIsZero() external {
        // It should revert
        // testing both bridge
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            0, // amount
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        vm.expectRevert(bytes('MintLimits: replenish amount cannot be 0'));
        router.execute{value: feeAmount}(commands, inputs);

        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            0, // amount
            feeAmount,
            0, // tokenFee
            leafDomain_2,
            true
        );

        vm.expectRevert(IXVeloTokenBridge.ZeroAmount.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenBridgeTypeIsInvalid() external {
        // It should revert with {InvalidBridgeType}
        inputs[0] = abi.encode(
            0,
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.InvalidBridgeType.selector, 0));
        router.execute{value: feeAmount}(commands, inputs);
    }

    modifier whenBasicValidationsPass() {
        _;
    }

    modifier whenBridgeTypeIsHYP_XERC20() {
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain,
            true
        );

        TestPostDispatchHook(address(rootMailbox.requiredHook())).setFee(MESSAGE_FEE);
        _;
    }

    function test_WhenTokenIsNotTheBridgeToken() external whenBasicValidationsPass whenBridgeTypeIsHYP_XERC20 {
        // It should revert — the bridge's transferRemote will fail on wrong token
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            leafDomain,
            true
        );

        vm.expectRevert();
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenNoTokenApprovalWasGiven() external whenBasicValidationsPass whenBridgeTypeIsHYP_XERC20 {
        // It should revert with {AllowanceExpired}

        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        router.execute{value: feeAmount}(commands, inputs);
    }

    modifier whenUsingPermit2() {
        ERC20(OPEN_USDT_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(OPEN_USDT_ADDRESS, address(router), type(uint160).max, type(uint48).max);
        _;
    }

    function test_WhenDomainIsZero() external whenBasicValidationsPass whenBridgeTypeIsHYP_XERC20 whenUsingPermit2 {
        // It should revert with "No router enrolled for domain: 0"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            0, // domain
            true
        );

        vm.expectRevert(bytes('No router enrolled for domain: 0'));
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsNotRegistered()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingPermit2
    {
        // It should revert with "No router enrolled for domain: 111"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            mockDomainId,
            true
        );

        vm.expectRevert(bytes('No router enrolled for domain: 111'));
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsTheSameAsSourceDomain()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingPermit2
    {
        // It should revert with "No router enrolled for domain: 10"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert(bytes('No router enrolled for domain: 10'));
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_RevertWhen_FeeIsInsufficient()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingPermit2
    {
        // It should revert
        vm.expectRevert(); // OutOfFunds
        router.execute{value: 0}(commands, inputs);
    }

    modifier whenAllChecksPass() {
        _;
    }

    modifier whenAmountIsContractBalanceHYP_XERC20() {
        commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.BRIDGE_TOKEN)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(router), Constants.TOTAL_BALANCE);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            ActionConstants.CONTRACT_BALANCE,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain,
            false
        );
        _;
    }

    function test_WhenAmountIsEqualToContractBalanceConstant()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingPermit2
        whenAllChecksPass
        whenAmountIsContractBalanceHYP_XERC20
    {
        // It should bridge the total router balance to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPEN_USDT_ADDRESS, openUsdtInitialBal, leafDomain
        );
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertOUsdt({_bridgeAmount: openUsdtInitialBal});

        // Assert excess fee was refunded
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS), 0);
    }

    function test_WhenAmountIsNotEqualToContractBalanceConstant()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingPermit2
        whenAllChecksPass
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPEN_USDT_ADDRESS, openUsdtBridgeAmount, leafDomain
        );
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertOUsdt({_bridgeAmount: openUsdtBridgeAmount});

        // Assert excess fee was refunded
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS), 0);
    }

    modifier whenUsingDirectApproval() {
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);
        _;
    }

    function test_WhenDomainIsZero_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingDirectApproval
    {
        // It should revert with "No router enrolled for domain: 0"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            0, // domain
            true
        );

        vm.expectRevert(bytes('No router enrolled for domain: 0'));
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsNotRegistered_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingDirectApproval
    {
        // It should revert with "No router enrolled for domain: 111"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            mockDomainId,
            true
        );

        vm.expectRevert(bytes('No router enrolled for domain: 111'));
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsTheSameAsSourceDomain_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingDirectApproval
    {
        // It should revert with "No router enrolled for domain: 10"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount,
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert(bytes('No router enrolled for domain: 10'));
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_RevertWhen_FeeIsInsufficient_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingDirectApproval
    {
        // It should revert
        vm.expectRevert(); // OutOfFunds
        router.execute{value: 0}(commands, inputs);
    }

    modifier whenAllChecksPass_() {
        _;
    }

    function test_WhenAmountIsEqualToContractBalanceConstant_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingDirectApproval
        whenAllChecksPass_
        whenAmountIsContractBalanceHYP_XERC20
    {
        // It should bridge the total router balance to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPEN_USDT_ADDRESS, openUsdtInitialBal, leafDomain
        );
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertOUsdt({_bridgeAmount: openUsdtInitialBal});

        // Assert excess fee was refunded
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS), 0);
    }

    function test_WhenAmountIsNotEqualToContractBalanceConstant_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_XERC20
        whenUsingDirectApproval
        whenAllChecksPass_
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPEN_USDT_ADDRESS, openUsdtBridgeAmount, leafDomain
        );
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertOUsdt({_bridgeAmount: openUsdtBridgeAmount});

        // Assert excess fee was refunded
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS), 0);
    }

    modifier whenBridgeTypeIsXVELO() {
        _;
    }

    modifier whenDestinationChainIsMETAL() {
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain_2,
            true
        );

        (, uint96 gasOverhead) = InterchainGasPaymaster(ROOT_IGP).destinationGasConfigs(leaf_2);
        uint256 gasLimit = rootXVeloTokenBridge.GAS_LIMIT() + gasOverhead;
        uint256 exchangeRate = 15000000000;
        uint256 tokenExchangeRate = 1e10;

        /// @dev Calculate gas price so that quote is `MESSAGE_FEE`
        uint256 requiredPrice = (MESSAGE_FEE * tokenExchangeRate) / (gasLimit * exchangeRate);

        // Mock the gas oracle response for domain 100001750
        bytes memory mockResponse = abi.encode(uint128(exchangeRate), uint128(requiredPrice));
        vm.mockCall(
            ROOT_STORAGE_GAS_ORACLE,
            abi.encodeWithSignature('getExchangeRateAndGasPrice(uint32)', leafDomain_2),
            mockResponse
        );
        _;
    }

    function test_WhenTokenIsNotTheBridgeToken_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
    {
        // It should revert with {InvalidTokenAddress}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            address(rootXVeloTokenBridge),
            1000, // openUSDT is 6 decimals so can't use xVeloBridgeAmount
            feeAmount,
            0, // tokenFee
            leafDomain_2,
            true
        );

        vm.expectRevert(BridgeRouter.InvalidTokenAddress.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenNoTokenApprovalWasGiven_()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
    {
        // It should revert with {AllowanceExpired}
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        router.execute{value: feeAmount}(commands, inputs);
    }

    modifier whenUsingPermit2_() {
        ERC20(VELO_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(VELO_ADDRESS, address(router), type(uint160).max, type(uint48).max);
        _;
    }

    function test_WhenDomainIsZero__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingPermit2_
    {
        // It should revert with {NotRegistered}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount,
            0, // tokenFee
            0, // domain
            true
        );

        vm.expectRevert(IDomainRegistry.NotRegistered.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsNotRegistered__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingPermit2_
    {
        // It should revert with {NotRegistered}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount,
            0, // tokenFee
            mockDomainId,
            true
        );

        vm.expectRevert(IDomainRegistry.NotRegistered.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsTheSameAsSourceDomain__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingPermit2_
    {
        // It should revert with {NotRegistered}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount,
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert(IDomainRegistry.NotRegistered.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenFeeIsInsufficient__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingPermit2_
    {
        // It should revert with "IGP: insufficient interchain gas payment"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            0, // fee amount
            0, // tokenFee
            leafDomain_2,
            true
        );

        vm.expectRevert('IGP: insufficient interchain gas payment');
        router.execute{value: 0}(commands, inputs);
    }

    modifier whenAllChecksPass__() {
        _;
    }

    modifier whenAmountIsContractBalanceXVELORoot() {
        commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.BRIDGE_TOKEN)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(VELO_ADDRESS, address(router), Constants.TOTAL_BALANCE);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            ActionConstants.CONTRACT_BALANCE,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain_2,
            false
        );
        _;
    }

    function test_WhenAmountIsEqualToContractBalanceConstant__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingPermit2_
        whenAllChecksPass__
        whenAmountIsContractBalanceXVELORoot
    {
        // It should bridge the total router balance to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, VELO_ADDRESS, xVeloInitialBal, leafDomain_2);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloInitialBal});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: rootId});
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootXVeloTokenBridge)), 0);
    }

    function test_WhenAmountIsNotEqualToContractBalanceConstant__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingPermit2_
        whenAllChecksPass__
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, VELO_ADDRESS, xVeloBridgeAmount, leafDomain_2);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloBridgeAmount});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: rootId});
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootXVeloTokenBridge)), 0);
    }

    modifier whenUsingDirectApproval_() {
        ERC20(VELO_ADDRESS).approve(address(router), type(uint256).max);
        _;
    }

    function test_WhenDomainIsZero___()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
    {
        // It should revert with {NotRegistered}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount,
            0, // tokenFee
            0, // domain
            true
        );

        vm.expectRevert(IDomainRegistry.NotRegistered.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsNotRegistered___()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
    {
        // It should revert with {NotRegistered}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount,
            0, // tokenFee
            mockDomainId,
            true
        );

        vm.expectRevert(IDomainRegistry.NotRegistered.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenDomainIsTheSameAsSourceDomain___()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
    {
        // It should revert with {NotRegistered}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount,
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert(IDomainRegistry.NotRegistered.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenFeeIsInsufficient___()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
    {
        // It should revert with "IGP: insufficient interchain gas payment"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            0, // fee amount
            0, // tokenFee
            leafDomain_2,
            true
        );

        vm.expectRevert('IGP: insufficient interchain gas payment');
        router.execute{value: 0}(commands, inputs);
    }

    modifier whenAllChecksPass___() {
        _;
    }

    function test_WhenAmountIsEqualToContractBalanceConstant___()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
        whenAllChecksPass___
        whenAmountIsContractBalanceXVELORoot
    {
        // It should bridge the total router balance to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, VELO_ADDRESS, xVeloInitialBal, leafDomain_2);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloInitialBal});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: rootId});
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootXVeloTokenBridge)), 0);
    }

    function test_WhenAmountIsNotEqualToContractBalanceConstant___()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
        whenAllChecksPass___
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, VELO_ADDRESS, xVeloBridgeAmount, leafDomain_2);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloBridgeAmount});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: rootId});
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootXVeloTokenBridge)), 0);
    }

    modifier whenDestinationChainIsOPTIMISM() {
        vm.selectFork(leafId_2);

        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            XVELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount + leftoverETH,
            0, // tokenFee
            rootDomain,
            true
        );

        (, uint96 gasOverhead) = InterchainGasPaymaster(LEAF_IGP_2).destinationGasConfigs(rootDomain);
        uint256 gasLimit = leafXVeloTokenBridge.GAS_LIMIT() + gasOverhead;
        uint256 exchangeRate = 15000000000;
        uint256 tokenExchangeRate = 1e10;

        /// @dev Calculate gas price so that quote is `MESSAGE_FEE`
        uint256 requiredPrice = (MESSAGE_FEE * tokenExchangeRate) / (gasLimit * exchangeRate);

        // Mock the gas oracle response for domain 10
        bytes memory mockResponse = abi.encode(uint128(exchangeRate), uint128(requiredPrice));
        vm.mockCall(
            LEAF_STORAGE_GAS_ORACLE,
            abi.encodeWithSignature('getExchangeRateAndGasPrice(uint32)', rootDomain),
            mockResponse
        );
        _;
    }

    function test_WhenTokenIsNotTheBridgeToken__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
    {
        // It should revert with {InvalidTokenAddress}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            address(rootXVeloTokenBridge),
            1000, // openUSDT is 6 decimals so can't use xVeloBridgeAmount
            feeAmount,
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert(BridgeRouter.InvalidTokenAddress.selector);
        leafRouter_2.execute{value: feeAmount}(commands, inputs);
    }

    function test_WhenNoTokenApprovalWasGiven__()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
    {
        // It should revert with {AllowanceExpired}
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        leafRouter_2.execute{value: feeAmount}(commands, inputs);
    }

    modifier whenUsingPermit2__() {
        ERC20(XVELO_ADDRESS).approve(address(leafPermit2_2), type(uint256).max);
        leafPermit2_2.approve(XVELO_ADDRESS, address(leafRouter_2), type(uint160).max, type(uint48).max);
        _;
    }

    function test_WhenFeeIsInsufficient____()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
        whenUsingPermit2__
    {
        // It should revert with "IGP: insufficient interchain gas payment"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            XVELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            0, // fee amount
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert('IGP: insufficient interchain gas payment');
        leafRouter_2.execute{value: 0}(commands, inputs);
    }

    function test_WhenAllChecksPass____()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
        whenUsingPermit2__
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, XVELO_ADDRESS, xVeloBridgeAmount, rootDomain);
        leafRouter_2.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloBridgeAmount});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: leafId_2});
        assertEq(ERC20(XVELO_ADDRESS).allowance(address(leafRouter_2), address(leafPermit2_2)), 0);
        assertEq(ERC20(XVELO_ADDRESS).allowance(address(leafRouter_2), address(leafXVeloTokenBridge)), 0);
    }

    modifier whenUsingDirectApproval__() {
        ERC20(XVELO_ADDRESS).approve(address(leafRouter_2), type(uint256).max);
        _;
    }

    function test_WhenFeeIsInsufficient_____()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
        whenUsingDirectApproval__
    {
        // It should revert with "IGP: insufficient interchain gas payment"
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            XVELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            0, // fee amount
            0, // tokenFee
            rootDomain,
            true
        );

        vm.expectRevert('IGP: insufficient interchain gas payment');
        leafRouter_2.execute{value: 0}(commands, inputs);
    }

    function test_WhenAllChecksPass_____()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
        whenUsingDirectApproval__
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event
        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(leafRouter_2));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, XVELO_ADDRESS, xVeloBridgeAmount, rootDomain);
        leafRouter_2.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloBridgeAmount});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: leafId_2});
        assertEq(ERC20(XVELO_ADDRESS).allowance(address(leafRouter_2), address(leafPermit2_2)), 0);
        assertEq(ERC20(XVELO_ADDRESS).allowance(address(leafRouter_2), address(leafXVeloTokenBridge)), 0);
    }

    function test_HypXERC20ChainedBridgeTokenFlow() external whenBridgeTypeIsHYP_XERC20 whenUsingDirectApproval {
        // Encode chained bridge command after transferFrom, so that payer is Router
        commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.BRIDGE_TOKEN)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(OPEN_USDT_ADDRESS, address(router), openUsdtBridgeAmount);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            openUsdtBridgeAmount,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain,
            false // payer is router
        );

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(OPEN_USDT_ADDRESS);
        emit ERC20.Transfer(users.alice, address(router), openUsdtBridgeAmount);
        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPEN_USDT_ADDRESS, openUsdtBridgeAmount, leafDomain
        );
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertOUsdt({_bridgeAmount: openUsdtBridgeAmount});

        // Assert excess fee was refunded
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: rootId});
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPEN_USDT_ADDRESS).allowance(address(router), OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS), 0);
    }

    function test_VeloChainedBridgeTokenFlow()
        external
        whenBridgeTypeIsXVELO
        whenDestinationChainIsMETAL
        whenUsingDirectApproval_
    {
        // Encode chained bridge command after transferFrom, so that payer is Router
        commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.BRIDGE_TOKEN)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(VELO_ADDRESS, address(router), xVeloBridgeAmount);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain_2,
            false // payer is router
        );

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(VELO_ADDRESS);
        emit ERC20.Transfer(users.alice, address(router), xVeloBridgeAmount);
        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, VELO_ADDRESS, xVeloBridgeAmount, leafDomain_2);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloBridgeAmount});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: rootId});
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(VELO_ADDRESS).allowance(address(router), address(rootXVeloTokenBridge)), 0);
    }

    function test_xVeloChainedBridgeTokenFlow()
        external
        whenBridgeTypeIsXVELO
        whenDestinationChainIsOPTIMISM
        whenUsingDirectApproval__
    {
        // Encode chained bridge command after transferFrom, so that payer is Router
        commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)), bytes1(uint8(Commands.BRIDGE_TOKEN)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(XVELO_ADDRESS, address(leafRouter_2), xVeloBridgeAmount);
        inputs[1] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            XVELO_ADDRESS,
            address(rootXVeloTokenBridge),
            xVeloBridgeAmount,
            feeAmount + leftoverETH,
            0, // tokenFee
            rootDomain,
            false // payer is router
        );

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(XVELO_ADDRESS);
        emit ERC20.Transfer(users.alice, address(leafRouter_2), xVeloBridgeAmount);
        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(users.alice, users.alice, XVELO_ADDRESS, xVeloBridgeAmount, rootDomain);
        leafRouter_2.execute{value: feeAmount + leftoverETH}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        _assertXVelo({_bridgeAmount: xVeloBridgeAmount});

        // Assert excess fee was refunded
        // @dev Allow delta to account for rounding
        assertApproxEqAbs(balanceAfter, balanceBefore - feeAmount, 1e14, 'Excess fee not refunded');
        // Assert no dangling ERC20 approvals
        vm.selectFork({forkId: leafId_2});
        assertEq(ERC20(XVELO_ADDRESS).allowance(address(leafRouter_2), address(leafPermit2_2)), 0);
        assertEq(ERC20(XVELO_ADDRESS).allowance(address(leafRouter_2), address(leafXVeloTokenBridge)), 0);
    }

    function _assertOUsdt(uint256 _bridgeAmount) private {
        // Verify token transfer occurred
        assertEq(
            ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice),
            openUsdtInitialBal - _bridgeAmount,
            'oUSDT balance should only contain leftover on root after bridge'
        );

        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        assertEq(
            ERC20(OPEN_USDT_ADDRESS).balanceOf(users.alice),
            _bridgeAmount,
            'oUSDT balance should match the bridge amount on leaf after bridge'
        );
    }

    /// HYP_ERC20_COLLATERAL TESTS ///

    modifier whenBridgeTypeIsHYP_ERC20_COLLATERAL() {
        // Uses deployed USDC HypERC20Collateral bridge on forked Optimism (5 bps fee for EVM-to-EVM)
        // No mocking needed — quoteTransferRemote hits the real on-chain contract

        // Add SWEEP command after BRIDGE_TOKEN to refund excess ETH
        commands = abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.SWEEP)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            OPTIMISM_USDC_ADDRESS,
            USDC_OPTIMISM_BRIDGE,
            usdcBridgeAmount, // amount
            feeAmount, // msgFee (all goes to mock mailbox hooks)
            usdcBridgeAmount, // maxTokenFee (generous cap for 5 bps fee)
            leafDomain,
            true
        );
        // SWEEP ETH back to caller (address(0) = ETH, MSG_SENDER = caller, 0 = no minimum)
        inputs[1] = abi.encode(Constants.ETH, ActionConstants.MSG_SENDER, 0);
        _;
    }

    function test_HypERC20Collateral_WhenTokenIsNotTheBridgeToken()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_ERC20_COLLATERAL
    {
        // It should revert with {InvalidTokenAddress}
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS, // wrong token
            USDC_OPTIMISM_BRIDGE,
            usdcBridgeAmount,
            feeAmount,
            usdcBridgeAmount,
            leafDomain,
            true
        );

        vm.expectRevert(BridgeRouter.InvalidTokenAddress.selector);
        router.execute{value: feeAmount}(commands, inputs);
    }

    function test_HypERC20Collateral_WhenNoTokenApprovalWasGiven()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_ERC20_COLLATERAL
    {
        // It should revert with {AllowanceExpired}
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.AllowanceExpired.selector, 0));
        router.execute{value: feeAmount}(commands, inputs);
    }

    modifier whenUsingPermit2ForHypERC20Collateral() {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(OPTIMISM_USDC_ADDRESS, address(router), type(uint160).max, type(uint48).max);
        _;
    }

    function test_HypERC20Collateral_WhenUsingPermit2()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_ERC20_COLLATERAL
        whenUsingPermit2ForHypERC20Collateral
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPTIMISM_USDC_ADDRESS, usdcBridgeAmount, leafDomain
        );
        router.execute{value: feeAmount}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        // Verify token transfer occurred — alice paid full amount (sendAmount + fee)
        assertEq(
            ERC20(OPTIMISM_USDC_ADDRESS).balanceOf(users.alice),
            usdcInitialBal - usdcBridgeAmount,
            'USDC balance should decrease by bridge amount'
        );

        // Assert ETH fee was consumed (sent to mock mailbox hooks)
        assertEq(balanceAfter, balanceBefore - feeAmount, 'ETH fee not consumed');
        // Assert no dangling ERC20 approvals
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).allowance(address(router), USDC_OPTIMISM_BRIDGE), 0);

        // Verify destination balance — process message on leaf chain and check recipient received USDC
        // The 5 bps fee is deducted, so recipient gets sendAmount < usdcBridgeAmount
        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        uint256 leafBalance = ERC20(BASE_USDC_ADDRESS).balanceOf(users.alice);
        // sendAmount = amount^2 / quoteAmount, with 5 bps fee: ~999.500 USDC for 1000 USDC input
        assertGt(leafBalance, 0, 'Should receive USDC on leaf');
        assertLt(leafBalance, usdcBridgeAmount, 'Should receive less than full amount due to fee');
        // 5 bps = 0.05%, so fee ~ 0.5 USDC on 1000 USDC
        assertApproxEqAbs(leafBalance, usdcBridgeAmount, USDC_1, 'Fee should be approximately 5 bps');
    }

    modifier whenUsingDirectApprovalForHypERC20Collateral() {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(router), type(uint256).max);
        _;
    }

    function test_HypERC20Collateral_WhenUsingDirectApproval()
        external
        whenBasicValidationsPass
        whenBridgeTypeIsHYP_ERC20_COLLATERAL
        whenUsingDirectApprovalForHypERC20Collateral
    {
        // It should bridge the amount to destination chain
        // It should return excess fee if any
        // It should leave no dangling ERC20 approvals
        // It should emit {UniversalRouterBridge} event

        uint256 balanceBefore = address(users.alice).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, OPTIMISM_USDC_ADDRESS, usdcBridgeAmount, leafDomain
        );
        router.execute{value: feeAmount}(commands, inputs);

        uint256 balanceAfter = address(users.alice).balance;

        // Verify token transfer occurred — alice paid full amount (sendAmount + fee)
        assertEq(
            ERC20(OPTIMISM_USDC_ADDRESS).balanceOf(users.alice),
            usdcInitialBal - usdcBridgeAmount,
            'USDC balance should decrease by bridge amount'
        );

        // Assert ETH fee was consumed (sent to mock mailbox hooks)
        assertEq(balanceAfter, balanceBefore - feeAmount, 'ETH fee not consumed');
        // Assert no dangling ERC20 approvals
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).allowance(address(router), address(rootPermit2)), 0);
        assertEq(ERC20(OPTIMISM_USDC_ADDRESS).allowance(address(router), USDC_OPTIMISM_BRIDGE), 0);

        // Verify destination balance — process message on leaf chain and check recipient received USDC
        vm.selectFork(leafId);
        leafMailbox.processNextInboundMessage();

        uint256 leafBalance = ERC20(BASE_USDC_ADDRESS).balanceOf(users.alice);
        assertGt(leafBalance, 0, 'Should receive USDC on leaf');
        assertLt(leafBalance, usdcBridgeAmount, 'Should receive less than full amount due to fee');
        assertApproxEqAbs(leafBalance, usdcBridgeAmount, USDC_1, 'Fee should be approximately 5 bps');
    }

    function testGas_HypERC20CollateralBridgePermit2() public whenBridgeTypeIsHYP_ERC20_COLLATERAL {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(OPTIMISM_USDC_ADDRESS, address(router), type(uint160).max, type(uint48).max);

        router.execute{value: feeAmount}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypERC20Collateral_Permit2');
    }

    function testGas_HypERC20CollateralBridgeDirectApproval() public whenBridgeTypeIsHYP_ERC20_COLLATERAL {
        ERC20(OPTIMISM_USDC_ADDRESS).approve(address(router), type(uint256).max);

        router.execute{value: feeAmount}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypERC20Collateral_DirectApproval');
    }

    /// HYP_NATIVE TESTS (HypNative routed via HYP_ERC20_COLLATERAL with token=address(0)) ///

    /// @dev Encodes a BRIDGE_TOKEN input for HypNative using the sentinel. `amount`
    /// is CONTRACT_BALANCE so the client passes identical structure to the ERC20
    /// flow — the router resolves the input from `address(this).balance` and
    /// computes fees via quoteTransferRemote.
    modifier whenBridgeTypeIsHYP_NATIVE() {
        commands = abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL), // sentinel: HypNative selected by token=address(0)
            ActionConstants.MSG_SENDER,
            Constants.ETH, // token=address(0) → native path
            address(hypNative),
            ActionConstants.CONTRACT_BALANCE, // consume router's native balance
            0, // msgFee unused on native path; branch forwards `amount` as value
            nativeBridgeAmount, // maxTokenFee cap
            leafDomain,
            false // payerIsUser: ignored on native path (no ERC20 pull)
        );
        _;
    }

    function _setHypNativeHookFee(uint256 fee) internal returns (uint256 hookFee) {
        TestPostDispatchHook(address(rootMailbox.requiredHook())).setFee(fee);
        TestPostDispatchHook(address(rootMailbox.defaultHook())).setFee(fee);
        hookFee = 2 * fee;
    }

    /// @dev Verify the bridged native arrives on the destination by processing the
    /// inbound mailbox message and asserting alice's leaf balance delta.
    function _assertHypNativeDelivery(uint256 bridgeAmount) private {
        vm.selectFork(leafId);
        uint256 before_ = users.alice.balance;
        leafMailbox.processNextInboundMessage();
        assertEq(users.alice.balance - before_, bridgeAmount, 'alice received bridgeAmount on leaf');
    }

    /// @notice Baseline: alice sends native as msg.value, router consumes full balance
    /// via CONTRACT_BALANCE. Recipient (= collateral on origin) credited 1:1.
    function test_HypNative_WhenNoFees() external whenBasicValidationsPass whenBridgeTypeIsHYP_NATIVE {
        uint256 aliceBefore = users.alice.balance;
        uint256 collateralBefore = address(hypNative).balance;

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, Constants.ETH, nativeBridgeAmount, leafDomain
        );
        router.execute{value: nativeBridgeAmount}(commands, inputs);

        assertEq(aliceBefore - users.alice.balance, nativeBridgeAmount, 'alice paid nativeBridgeAmount');
        assertEq(
            address(hypNative).balance - collateralBefore,
            nativeBridgeAmount,
            'collateral credited full bridgeAmount (no fees)'
        );
        assertEq(address(router).balance, 0, 'router drained');

        _assertHypNativeDelivery(nativeBridgeAmount);
    }

    /// @notice Hook fee: same client logic (CONTRACT_BALANCE + maxTokenFee cap). The
    /// router auto-deducts the hook fee from the balance — caller forwards the total
    /// as msg.value and the bridge credits `amount - hookFee` to the recipient.
    function test_HypNative_WithHookFee() external whenBasicValidationsPass whenBridgeTypeIsHYP_NATIVE {
        uint256 hookFee = _setHypNativeHookFee(0.001 ether);
        uint256 totalIn = nativeBridgeAmount + hookFee;

        uint256 aliceBefore = users.alice.balance;
        uint256 collateralBefore = address(hypNative).balance;

        router.execute{value: totalIn}(commands, inputs);

        assertEq(aliceBefore - users.alice.balance, totalIn, 'alice paid totalIn');
        assertEq(
            address(hypNative).balance - collateralBefore,
            nativeBridgeAmount,
            'collateral credited bridgeAmount (hook fee absorbed)'
        );
        assertEq(address(router).balance, 0, 'router drained');

        _assertHypNativeDelivery(nativeBridgeAmount);
    }

    /// @notice Linear warp fee: same client logic. For rate=1%, totalIn=1.01 ETH
    /// bridges exactly 1 ETH (quoteExactInputBridgeAmount resolves to amount²/(amount+f(amount))).
    function test_HypNative_WithLinearWarpFee() external whenBasicValidationsPass whenBridgeTypeIsHYP_NATIVE {
        uint256 expectedBridge = 1 ether;
        uint256 totalIn = 1.01 ether; // rate 1%
        // override amount and maxTokenFee for the 1%-rate math
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            Constants.ETH,
            address(hypNative),
            ActionConstants.CONTRACT_BALANCE,
            0,
            totalIn - expectedBridge,
            leafDomain,
            false
        );

        vm.stopPrank();
        LinearFee linearFee = new LinearFee(address(0), 0.02 ether, 1 ether, users.owner);
        vm.prank(users.owner);
        hypNative.setFeeRecipient(address(linearFee));
        vm.startPrank(users.alice);

        uint256 collateralBefore = address(hypNative).balance;

        router.execute{value: totalIn}(commands, inputs);

        assertEq(
            address(hypNative).balance - collateralBefore,
            expectedBridge,
            'collateral credited 1 ETH bridgeAmount'
        );
        assertEq(address(linearFee).balance, totalIn - expectedBridge, 'linear fee recipient got overage');
        assertEq(address(router).balance, 0, 'router drained');

        _assertHypNativeDelivery(expectedBridge);
    }

    function test_HypNative_WhenTokenFeeExceedsMax() external whenBasicValidationsPass whenBridgeTypeIsHYP_NATIVE {
        uint256 hookFee = _setHypNativeHookFee(0.001 ether);
        uint256 totalIn = nativeBridgeAmount + hookFee;

        // Tighten maxTokenFee to 1 wei below the actual fee
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            Constants.ETH,
            address(hypNative),
            ActionConstants.CONTRACT_BALANCE,
            0,
            hookFee - 1,
            leafDomain,
            false
        );

        vm.expectRevert(abi.encodeWithSelector(BridgeRouter.TokenFeeExceedsMax.selector, hookFee, hookFee - 1));
        router.execute{value: totalIn}(commands, inputs);
    }

    /// @notice Origin-side ERC20→native→bridge composition with the same client
    /// logic as the ERC20 collateral flow: TRANSFER_FROM + BRIDGE_TOKEN(CONTRACT_BALANCE).
    /// WETH is unwrapped between the steps so the bridge sees native.
    function test_HypNative_WethToNative_ThenBridge() external {
        uint256 wethIn = nativeBridgeAmount;
        weth.deposit{value: wethIn}();
        weth.approve(address(router), type(uint256).max);

        commands = abi.encodePacked(
            bytes1(uint8(Commands.TRANSFER_FROM)),
            bytes1(uint8(Commands.UNWRAP_WETH)),
            bytes1(uint8(Commands.BRIDGE_TOKEN))
        );
        inputs = new bytes[](3);
        inputs[0] = abi.encode(address(weth), address(router), wethIn);
        inputs[1] = abi.encode(ActionConstants.ADDRESS_THIS, 0);
        inputs[2] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            Constants.ETH,
            address(hypNative),
            ActionConstants.CONTRACT_BALANCE,
            0,
            nativeBridgeAmount,
            leafDomain,
            false
        );

        uint256 collateralBefore = address(hypNative).balance;

        router.execute(commands, inputs);

        assertEq(
            address(hypNative).balance - collateralBefore,
            wethIn,
            'collateral credited full WETH-derived native'
        );
        assertEq(address(router).balance, 0, 'router drained');

        _assertHypNativeDelivery(wethIn);
    }

    /// @notice Combined native hook + linear warp fees with plain CONTRACT_BALANCE.
    /// Router resolves input from balance, quote deducts both fees, client passes
    /// no pre-computation. For rate=1% and hookFee, totalIn = 1.01 ETH + hookFee →
    /// bridgeAmount = 1 ETH.
    function test_HypNative_WithCombinedFees() external whenBasicValidationsPass whenBridgeTypeIsHYP_NATIVE {
        uint256 hookFee = _setHypNativeHookFee(0.0005 ether);
        uint256 expectedBridge = 1 ether;
        uint256 totalIn = 1.01 ether + hookFee; // linear 1% + hook

        vm.stopPrank();
        LinearFee linearFee = new LinearFee(address(0), 0.02 ether, 1 ether, users.owner);
        vm.prank(users.owner);
        hypNative.setFeeRecipient(address(linearFee));
        vm.startPrank(users.alice);

        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            Constants.ETH,
            address(hypNative),
            ActionConstants.CONTRACT_BALANCE,
            0,
            totalIn - expectedBridge,
            leafDomain,
            false
        );

        uint256 collateralBefore = address(hypNative).balance;

        router.execute{value: totalIn}(commands, inputs);

        assertEq(
            address(hypNative).balance - collateralBefore,
            expectedBridge,
            'collateral credited bridgeAmount (hook + linear absorbed)'
        );
        assertEq(address(linearFee).balance, totalIn - expectedBridge - hookFee, 'linear fee = totalIn - bridge - hook');
        assertEq(address(router).balance, 0, 'router drained');

        _assertHypNativeDelivery(expectedBridge);
    }

    function testGas_HypNativeBridge() public whenBridgeTypeIsHYP_NATIVE {
        router.execute{value: nativeBridgeAmount}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypNative');
    }

    /// @notice Gas snapshot for the "router already holds native" path (e.g. after a
    /// preceding swap+unwrap). Mirrors testGas_HypXERC20BridgeRouterBalance.
    function testGas_HypNativeBridgeRouterBalance() public whenBridgeTypeIsHYP_NATIVE {
        vm.deal(address(router), nativeBridgeAmount);
        router.execute(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypNative_RouterBalance');
    }

    /// HYP_ERC20 SYNTHETIC TESTS (mint/burn — token() == address(this), so token == bridge in encoding) ///

    modifier whenBridgeTypeIsHYP_ERC20_SYNTHETIC() {
        commands = abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN)), bytes1(uint8(Commands.SWEEP)));
        inputs = new bytes[](2);
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            address(hypERC20), // token
            address(hypERC20), // bridge (synthetic: token == bridge)
            hypERC20BridgeAmount,
            feeAmount,
            hypERC20BridgeAmount, // generous maxTokenFee
            leafDomain,
            true
        );
        inputs[1] = abi.encode(Constants.ETH, ActionConstants.MSG_SENDER, 0);
        _;
    }

    /// @dev Verify the bridged HypERC20 arrives on the destination by processing the
    /// inbound mailbox message and asserting alice's leaf balance delta (minted).
    function _assertHypERC20Delivery(uint256 bridgeAmount) private {
        vm.selectFork(leafId);
        uint256 before_ = leafHypERC20.balanceOf(users.alice);
        leafMailbox.processNextInboundMessage();
        assertEq(leafHypERC20.balanceOf(users.alice) - before_, bridgeAmount, 'alice received bridgeAmount on leaf');
    }

    /// @notice Vanilla synthetic bridge with no fees configured. quoteExactInputBridgeAmount
    /// collapses to bridgeAmount = amount (since linearQuotedTokens = amount). Router pulls
    /// `amount` from alice, calls transferRemote(amount) which burns from router; leaf mints
    /// to alice on delivery.
    function test_HypERC20_WhenNoFees() external whenBasicValidationsPass whenBridgeTypeIsHYP_ERC20_SYNTHETIC {
        hypERC20.approve(address(router), type(uint256).max);

        uint256 aliceBefore = hypERC20.balanceOf(users.alice);
        uint256 supplyBefore = hypERC20.totalSupply();

        vm.expectEmit(address(router));
        emit Dispatcher.UniversalRouterBridge(
            users.alice, users.alice, address(hypERC20), hypERC20BridgeAmount, leafDomain
        );
        router.execute{value: feeAmount}(commands, inputs);

        assertEq(aliceBefore - hypERC20.balanceOf(users.alice), hypERC20BridgeAmount, 'alice paid bridgeAmount');
        assertEq(hypERC20.balanceOf(address(router)), 0, 'router drained');
        assertEq(supplyBefore - hypERC20.totalSupply(), hypERC20BridgeAmount, 'supply burned by bridgeAmount');
        assertEq(hypERC20.allowance(address(router), address(hypERC20)), 0, 'no dangling approval');

        _assertHypERC20Delivery(hypERC20BridgeAmount);
    }

    /// @notice With LinearFee at 1% rate: alice supplies 1.01 ether, bridges 1 ether, fee
    /// recipient receives 0.01 ether (minted). Mirrors test_HypNative_WithLinearWarpFee.
    function test_HypERC20_WithLinearFee() external whenBasicValidationsPass whenBridgeTypeIsHYP_ERC20_SYNTHETIC {
        uint256 expectedBridge = 1 ether;
        uint256 totalIn = 1.01 ether;

        // Override amount and maxTokenFee for the 1%-rate math
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_ERC20_COLLATERAL),
            ActionConstants.MSG_SENDER,
            address(hypERC20),
            address(hypERC20),
            totalIn,
            feeAmount,
            totalIn - expectedBridge,
            leafDomain,
            true
        );

        vm.stopPrank();
        LinearFee linearFee = new LinearFee(address(hypERC20), 0.02 ether, 1 ether, users.owner);
        vm.prank(users.owner);
        hypERC20.setFeeRecipient(address(linearFee));
        vm.startPrank(users.alice);

        hypERC20.approve(address(router), type(uint256).max);

        uint256 aliceBefore = hypERC20.balanceOf(users.alice);

        router.execute{value: feeAmount}(commands, inputs);

        assertEq(aliceBefore - hypERC20.balanceOf(users.alice), totalIn, 'alice paid totalIn');
        assertEq(
            hypERC20.balanceOf(address(linearFee)), totalIn - expectedBridge, 'linear fee recipient minted overage'
        );
        assertEq(hypERC20.balanceOf(address(router)), 0, 'router drained');

        _assertHypERC20Delivery(expectedBridge);
    }

    function testGas_HypERC20Bridge() public whenBridgeTypeIsHYP_ERC20_SYNTHETIC {
        hypERC20.approve(address(router), type(uint256).max);
        router.execute{value: feeAmount}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypERC20_Synthetic');
    }

    function _assertXVelo(uint256 _bridgeAmount) private {
        if (vm.activeFork() == rootId) {
            // Verify token transfer occurred
            assertEq(
                ERC20(VELO_ADDRESS).balanceOf(users.alice),
                xVeloInitialBal - _bridgeAmount,
                'VELO balance should only contain leftover on root after bridge'
            );

            vm.selectFork(leafId_2);
            leafMailbox_2.processNextInboundMessage();

            assertEq(
                ERC20(XVELO_ADDRESS).balanceOf(users.alice) - xVeloInitialBal, // account for initial balance minted in setup
                _bridgeAmount,
                'XVELO balance should match the bridge amount on leaf after bridge'
            );
        } else {
            // Verify token transfer occurred
            assertEq(
                ERC20(XVELO_ADDRESS).balanceOf(users.alice),
                xVeloInitialBal - _bridgeAmount,
                'XVELO balance only contain leftover on leaf after bridge'
            );

            vm.selectFork(rootId);
            rootMailbox.processNextInboundMessage();

            assertEq(
                ERC20(VELO_ADDRESS).balanceOf(users.alice) - xVeloInitialBal, // account for initial balance minted in setup
                _bridgeAmount,
                'VELO balance should match the bridge amount on root after bridge'
            );
        }
    }

    /// GAS CHECKS ///

    function testGas_HypXERC20BridgePermit2() public whenBridgeTypeIsHYP_XERC20 {
        ERC20(OPEN_USDT_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(OPEN_USDT_ADDRESS, address(router), type(uint160).max, type(uint48).max);

        router.execute{value: feeAmount + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypXERC20_Permit2');
    }

    function testGas_HypXERC20BridgeDirectApproval() public whenBridgeTypeIsHYP_XERC20 {
        ERC20(OPEN_USDT_ADDRESS).approve(address(router), type(uint256).max);

        router.execute{value: feeAmount + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypXERC20_DirectApproval');
    }

    function testGas_HypXERC20BridgeRouterBalance() public whenBridgeTypeIsHYP_XERC20 {
        inputs[0] = abi.encode(
            uint8(BridgeTypes.HYP_XERC20),
            ActionConstants.MSG_SENDER,
            OPEN_USDT_ADDRESS,
            OPEN_USDT_OPTIMISM_BRIDGE_ADDRESS,
            ActionConstants.CONTRACT_BALANCE,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain,
            false
        );

        deal(OPEN_USDT_ADDRESS, address(router), openUsdtBridgeAmount);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_HypXERC20_RouterBalance');
    }

    function testGas_XVeloBridgePermit2() public whenBridgeTypeIsXVELO whenDestinationChainIsMETAL {
        ERC20(VELO_ADDRESS).approve(address(rootPermit2), type(uint256).max);
        rootPermit2.approve(VELO_ADDRESS, address(router), type(uint160).max, type(uint48).max);

        router.execute{value: feeAmount + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_XVelo_Permit2');
    }

    function testGas_XVeloBridgeDirectApproval() public whenBridgeTypeIsXVELO whenDestinationChainIsMETAL {
        ERC20(VELO_ADDRESS).approve(address(router), type(uint256).max);

        router.execute{value: feeAmount + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_XVelo_DirectApproval');
    }

    function testGas_XVeloBridgeRouterBalance() public whenBridgeTypeIsXVELO whenDestinationChainIsMETAL {
        inputs[0] = abi.encode(
            uint8(BridgeTypes.XVELO),
            ActionConstants.MSG_SENDER,
            VELO_ADDRESS,
            address(rootXVeloTokenBridge),
            ActionConstants.CONTRACT_BALANCE,
            feeAmount + leftoverETH,
            0, // tokenFee
            leafDomain_2,
            false
        );

        deal(VELO_ADDRESS, address(router), xVeloBridgeAmount);
        router.execute{value: feeAmount + leftoverETH}(commands, inputs);
        vm.snapshotGasLastCall('BridgeRouter_XVelo_RouterBalance');
    }
}
