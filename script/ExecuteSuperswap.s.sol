// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from 'forge-std/Script.sol';

// Minimal interfaces to avoid importing full contracts
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

interface IInterchainAccountRouter {
    function routers(uint32 domain) external view returns (bytes32);
    function hook() external view returns (address);
    function quoteGasPayment(uint32 _destination) external view returns (uint256);
    function quoteGasForCommitReveal(uint32 _destination, uint256 gasLimit) external view returns (uint256);
    function getRemoteInterchainAccount(
        uint32 _destination,
        address _owner,
        bytes32 _userSalt
    ) external view returns (address);
}

interface IQuoteTransferRemote {
    struct Quote {
        address token;
        uint256 amount;
    }
    function quoteTransferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount
    ) external view returns (Quote[] memory quotes);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }
    
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}

library TypeCasts {
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}

library CallLib {
    struct Call {
        bytes32 to;
        uint256 value;
        bytes data;
    }

    function build(address to, uint256 value, bytes memory data) internal pure returns (Call memory) {
        return Call({to: TypeCasts.addressToBytes32(to), value: value, data: data});
    }
}

contract ExecuteSuperswap is Script {
    // ===== Command Constants =====
    uint8 constant WRAP_ETH = 0x0b;
    uint8 constant V3_SWAP_EXACT_IN = 0x00;
    uint8 constant BRIDGE_TOKEN = 0x12;
    uint8 constant EXECUTE_CROSS_CHAIN = 0x13;
    uint8 constant SWEEP = 0x04;
    uint8 constant EXECUTE_SUB_PLAN = 0x21;  // Fixed: was 0x11 which is V4_INITIALIZE_POOL
    uint8 constant TRANSFER_FROM = 0x07;     // Fixed: was 0x06 which is PAY_PORTION
    uint8 constant FLAG_ALLOW_REVERT = 0x80;
    
    // ===== Bridge Type Constants =====
    uint8 constant HYP_ERC20_COLLATERAL = 0x03;
    
    // ===== Action Constants =====
    address constant ADDRESS_THIS = address(2);
    uint256 constant CONTRACT_BALANCE = type(uint256).max;
    uint256 constant TOTAL_BALANCE = type(uint256).max;
    
    // ===== Optimism Addresses =====
    IUniversalRouter constant ROUTER = IUniversalRouter(0xa9606caaC711Ac816E568356187EC7a009500Eb2);
    address constant WETH_OPTIMISM = 0x4200000000000000000000000000000000000006;
    address constant USDC_OPTIMISM = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant USDC_BRIDGE_OPTIMISM = 0x02bFd67829317D666dc7dFA030F18eaCC12c2cfb;
    IInterchainAccountRouter constant ICA_ROUTER_OPTIMISM = IInterchainAccountRouter(0x3E343D07D024E657ECF1f8Ae8bb7a12f08652E75);
    // Old quoter using factory 0xCc0bDDB707055e04e497aB22a59c2aF4391cd12F (matches router config)
    IQuoterV2 constant VELO_QUOTER = IQuoterV2(0x89D8218ed5fF1e46d8dcd33fb0bbeE3be1621466);
    
    // ===== Unichain Addresses =====
    uint32 constant UNICHAIN_DOMAIN = 130;
    address constant ROUTER_UNICHAIN = 0xa9606caaC711Ac816E568356187EC7a009500Eb2;
    address constant WETH_UNICHAIN = 0x4200000000000000000000000000000000000006;
    address constant USDC_UNICHAIN = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    
    // ===== User =====
    address public user;
    
    function run() public {
        user = msg.sender;
        console.log("User:", user);
        
        // Amount to swap: 0.001 ETH
        uint256 wethAmountIn = 0.001 ether;
        
        // Step 1: Get quotes
        console.log("\n=== Step 1: Get Quotes ===");
        
        // Quote the swap to get expected USDC output
        uint256 expectedUsdcOut = quoteSwap(wethAmountIn);
        console.log("Expected USDC from swap:", expectedUsdcOut);
        
        // Apply slippage tolerance (1%)
        uint256 minUsdcOut = expectedUsdcOut * 99 / 100;
        console.log("Min USDC out (1% slippage):", minUsdcOut);
        
        // Get bridge quote using minUsdcOut
        (uint256 bridgeMsgFee, uint256 bridgeTokenFee) = getBridgeQuote(minUsdcOut);
        console.log("Bridge msg fee (wei):", bridgeMsgFee);
        console.log("Bridge token fee (USDC):", bridgeTokenFee);
        
        // Get ICA quote from the router - need to quote for both commit and reveal messages
        // Use a reasonable gas limit for the reveal transaction (e.g., 500k for swap execution)
        uint256 revealGasLimit = 500_000;
        uint256 icaMsgFee = ICA_ROUTER_OPTIMISM.quoteGasForCommitReveal(UNICHAIN_DOMAIN, revealGasLimit);
        console.log("ICA msg fee (wei) for commit+reveal:", icaMsgFee);
        
        // Step 2: Predict user's ICA address on Unichain
        console.log("\n=== Step 2: Predict ICA Address ===");
        address userICA = ICA_ROUTER_OPTIMISM.getRemoteInterchainAccount({
            _destination: UNICHAIN_DOMAIN,
            _owner: address(ROUTER),
            _userSalt: TypeCasts.addressToBytes32(user)
        });
        console.log("User ICA on Unichain:", userICA);
        
        // Step 3: Build destination commands (swap USDC -> WETH on Unichain)
        console.log("\n=== Step 3: Build Destination Commands ===");
        
        // Destination swap path: USDC -> WETH on Unichain
        // Note: Unichain has Uniswap V4 - need correct tick spacing for the pool
        bytes memory destSwapPath = abi.encodePacked(
            USDC_UNICHAIN,
            int24(100),            // tick spacing - need to verify pool exists
            WETH_UNICHAIN
        );
        
        // Swap subplan - use minUsdcOut since transferRemote delivers exact amount
        bytes memory swapSubplan = abi.encodePacked(bytes1(V3_SWAP_EXACT_IN));
        bytes[] memory swapInputs = new bytes[](1);
        swapInputs[0] = abi.encode(
            user,                  // recipient
            minUsdcOut,            // amountIn - exact amount bridged (transferRemote has exact-out semantics)
            uint256(1),            // amountOutMin
            destSwapPath,          // path
            true,                  // payerIsUser - ICA approved router, so router pulls from ICA
            false                  // isUni = false for Velodrome-style pools
        );
        
        // Fallback transfer subplan
        bytes memory transferSubplan = abi.encodePacked(bytes1(TRANSFER_FROM));
        bytes[] memory transferInputs = new bytes[](1);
        transferInputs[0] = abi.encode(USDC_UNICHAIN, user, TOTAL_BALANCE);
        
        // Combine into leaf commands
        bytes memory leafCommands = abi.encodePacked(
            bytes1(EXECUTE_SUB_PLAN | FLAG_ALLOW_REVERT),
            bytes1(EXECUTE_SUB_PLAN | FLAG_ALLOW_REVERT)
        );
        bytes[] memory leafInputs = new bytes[](2);
        leafInputs[0] = abi.encode(swapSubplan, swapInputs);
        leafInputs[1] = abi.encode(transferSubplan, transferInputs);
        
        // Step 4: Build ICA calls
        console.log("\n=== Step 4: Build ICA Calls ===");
        
        CallLib.Call[] memory calls = new CallLib.Call[](3);
        calls[0] = CallLib.build(USDC_UNICHAIN, 0, abi.encodeCall(IERC20.approve, (ROUTER_UNICHAIN, type(uint256).max)));
        calls[1] = CallLib.build(ROUTER_UNICHAIN, 0, abi.encodeCall(IUniversalRouter.execute, (leafCommands, leafInputs)));
        calls[2] = CallLib.build(USDC_UNICHAIN, 0, abi.encodeCall(IERC20.approve, (ROUTER_UNICHAIN, 0)));
        
        // Step 5: Calculate commitment hash
        console.log("\n=== Step 5: Calculate Commitment ===");
        bytes32 salt = TypeCasts.addressToBytes32(user);
        bytes memory encodedCalls = abi.encode(calls);
        bytes32 commitment = keccak256(abi.encodePacked(salt, encodedCalls));
        console.log("Commitment hash:");
        console.logBytes32(commitment);
        
        // Log the ICA calls for API submission
        console.log("\n=== ICA Calls Payload (for API) ===");
        console.log("{");
        console.log('  "calls": [');
        for (uint i = 0; i < calls.length; i++) {
            console.log("    {");
            console.log('      "to": "%s",', vm.toString(calls[i].to));
            console.log('      "value": "%s",', vm.toString(calls[i].value));
            console.log('      "data": "%s"', vm.toString(calls[i].data));
            if (i < calls.length - 1) {
                console.log("    },");
            } else {
                console.log("    }");
            }
        }
        console.log("  ],");
        console.log('  "salt": "%s",', vm.toString(salt));
        console.log('  "originDomain": 10');
        console.log("}");
        console.log("(Add commitmentDispatchTx after broadcast)");
        
        // Step 6: Build origin commands
        console.log("\n=== Step 6: Build Origin Commands ===");
        
        // Commands: WRAP_ETH -> V3_SWAP -> BRIDGE_TOKEN -> EXECUTE_CROSS_CHAIN -> SWEEP
        bytes memory originCommands = abi.encodePacked(
            bytes1(WRAP_ETH),
            bytes1(V3_SWAP_EXACT_IN),
            bytes1(BRIDGE_TOKEN),
            bytes1(EXECUTE_CROSS_CHAIN),
            bytes1(SWEEP)
        );
        
        bytes[] memory originInputs = new bytes[](5);
        
        // Input 0: WRAP_ETH
        originInputs[0] = abi.encode(ADDRESS_THIS, wethAmountIn);
        
        // Input 1: V3_SWAP_EXACT_IN (WETH -> USDC on Velodrome CL, tick spacing 100)
        // NOTE: Must use specific amount, not CONTRACT_BALANCE, due to CalldataDecoder issue
        bytes memory originSwapPath = abi.encodePacked(WETH_OPTIMISM, int24(100), USDC_OPTIMISM);
        originInputs[1] = abi.encode(
            ADDRESS_THIS,        // recipient
            wethAmountIn,        // amountIn (use specific amount, not CONTRACT_BALANCE)
            minUsdcOut,          // amountOutMin
            originSwapPath,      // path
            false,               // payerIsUser
            false                // isUni (Velodrome)
        );
        
        // Input 2: BRIDGE_TOKEN
        originInputs[2] = abi.encode(
            HYP_ERC20_COLLATERAL,
            userICA,
            USDC_OPTIMISM,
            USDC_BRIDGE_OPTIMISM,
            minUsdcOut,          // amount to bridge
            bridgeMsgFee,        // msgFee
            bridgeTokenFee,      // tokenFee
            UNICHAIN_DOMAIN,
            false                // payerIsUser
        );
        
        // Input 3: EXECUTE_CROSS_CHAIN
        // Note: token must be a valid contract address even if tokenFee is 0,
        // because Dispatcher unconditionally calls token.approve()
        // Note: The Dispatcher hardcodes _salt = msgSender() when calling callRemoteCommitReveal
        originInputs[3] = abi.encode(
            UNICHAIN_DOMAIN,
            address(ICA_ROUTER_OPTIMISM),
            ICA_ROUTER_OPTIMISM.routers(UNICHAIN_DOMAIN),
            bytes32(0),          // ISM override (0 = use default)
            commitment,
            icaMsgFee,
            WETH_OPTIMISM,       // Use WETH as dummy token (must be valid contract)
            uint256(0),          // tokenFee = 0
            ICA_ROUTER_OPTIMISM.hook(),
            new bytes(0)
        );
        
        // Input 4: SWEEP (return excess USDC to user)
        originInputs[4] = abi.encode(USDC_OPTIMISM, user, uint256(0));
        
        // Step 7: Execute
        console.log("\n=== Step 7: Execute ===");
        uint256 totalValue = wethAmountIn + bridgeMsgFee + icaMsgFee;
        console.log("Total ETH to send:", totalValue);
        
        vm.startBroadcast();
        ROUTER.execute{value: totalValue}(originCommands, originInputs);
        vm.stopBroadcast();
        
        console.log("\n=== Success! ===");
        console.log("Origin transaction complete.");
        console.log("Wait for Hyperlane to deliver messages, then call revealAndExecute on the ICA.");
    }
    
    function getBridgeQuote(uint256 amount) internal view returns (uint256 msgFee, uint256 tokenFee) {
        bytes32 recipient = TypeCasts.addressToBytes32(address(0x1));
        IQuoteTransferRemote.Quote[] memory quotes = IQuoteTransferRemote(USDC_BRIDGE_OPTIMISM)
            .quoteTransferRemote(UNICHAIN_DOMAIN, recipient, amount);
        msgFee = quotes[0].amount;
        tokenFee = quotes[1].amount + quotes[2].amount;
    }
    
    function quoteSwap(uint256 amountIn) internal returns (uint256 amountOut) {
        (amountOut,,,) = VELO_QUOTER.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: WETH_OPTIMISM,
                tokenOut: USDC_OPTIMISM,
                amountIn: amountIn,
                tickSpacing: 100,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
