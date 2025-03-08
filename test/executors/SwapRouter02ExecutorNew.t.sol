// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

// Contract under test
import {SwapRouter02ExecutorNew} from "src/sample-executors/SwapRouter02ExecutorNew.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {IReactor} from "src/interfaces/IReactor.sol";
import {IBebopSettlement} from "../../BebopSettlement/src/interface/IBebopSettlement.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PermitSignature} from "../util/PermitSignature.sol";
import {SwapRouter02Executor} from "../../src/sample-executors/SwapRouter02Executor.sol";
import {MockSwapRouter} from "../util/mock/MockSwapRouter.sol";
import {DutchOrderReactor} from "../../src/reactors/DutchOrderReactor.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {ISwapRouter02} from "../../src/external/ISwapRouter02.sol";
import {Order} from "../../BebopSettlement/src/libs/Order.sol";
import {ResolvedOrder, OrderInfo, SignedOrder} from "../../src/base/ReactorStructs.sol";
import {Signature} from "../../BebopSettlement/src/libs/Signature.sol";
import {BebopSettlement} from "../../BebopSettlement/src/BebopSettlement.sol";
import {ERC1271WalletMock} from "permit2/lib/openzeppelin-contracts/contracts/mocks/ERC1271WalletMock.sol";
import "lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {ExclusiveDutchOrder, DutchOutput, DutchInput} from "../../src/reactors/ExclusiveDutchOrderReactor.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {ExclusiveDutchOrderReactor, ExclusiveDutchOrder, ResolvedOrder, DutchOutput, DutchInput, BaseReactor} from "../../src/reactors/ExclusiveDutchOrderReactor.sol";

contract SwapRouter02ExecutorNewTest is Test, PermitSignature, DeployPermit2 {
    using OrderInfoBuilder for OrderInfo;

    address internal owner;
    address internal whitelisted;
    address internal nonWhitelisted;

    // uint256 fillerPrivateKey;
    uint256 swapperPrivateKey;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    WETH weth;
    address filler;
    address swapper;
    SwapRouter02ExecutorNew swapRouter02ExecutorNew;
    MockSwapRouter mockSwapRouter;
    ExclusiveDutchOrderReactor reactor;
    IPermit2 permit2;
    BebopSettlement internal bebopTest;
    ERC1271WalletMock internal erc1271WalletMock;

    address constant PROTOCOL_FEE_OWNER = address(80085);

    // to test sweeping ETH
    receive() external payable {}

    function setUp() public {
        vm.warp(1000);
        // Mock input/output tokens
        tokenIn = new MockERC20("Input", "IN", 18);
        tokenOut = new MockERC20("Output", "OUT", 18);
        weth = new WETH();

        // Mock filler and swapper
        // fillerPrivateKey = 0x12341234;
        // filler = vm.addr(fillerPrivateKey);
        swapperPrivateKey = 0x12341235;
        swapper = vm.addr(swapperPrivateKey);

        // Instantiate relevant contracts
        mockSwapRouter = new MockSwapRouter(address(weth));
        permit2 = IPermit2(deployPermit2());
        reactor = new ExclusiveDutchOrderReactor(permit2, PROTOCOL_FEE_OWNER);
        tokenIn.approve(address(permit2), 2);
        tokenOut.approve(address(permit2), type(uint256).max);

        bebopTest = new BebopSettlement(
            address(weth),
            address(permit2),
            address(0x6B175474E89094C44Da98b954EedeAC495271d0F)
        );

        swapRouter02ExecutorNew = new SwapRouter02ExecutorNew(
            address(this),
            reactor,
            address(this),
            ISwapRouter02(address(mockSwapRouter)),
            IBebopSettlement(address(bebopTest))
        );

        tokenIn.forceApprove(
            address(swapRouter02ExecutorNew),
            address(swapRouter02ExecutorNew),
            type(uint256).max
        );

        tokenIn.forceApprove(swapper, address(permit2), type(uint256).max);
    }

    function testPermit() public {
        address owner = vm.addr(1);
        address spender = address(this); // Contract that will spend tokens
        uint256 value = 1000 ether; // Amount to approve
        uint256 deadline = block.timestamp + 1 hours; // Expiration time

        // Compute the hash that needs to be signed
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                tokenIn.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                        ),
                        owner,
                        spender,
                        value,
                        tokenIn.nonces(owner),
                        deadline
                    )
                )
            )
        );

        // Sign the digest with the maker's private key (off-chain signer)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        tokenIn.permit(owner, spender, value, deadline, v, r, s);

        // bebopTest calls permit() with the signed data
        assertEq(tokenIn.allowance(owner, spender), value);
    }

    function createProfitableBebopOrder() public returns (bytes memory) {
        uint256 makerPrivateKey = 0x1234123412341234123412341234123412341234123412341234123412341234;
        address makerAddress = vm.addr(makerPrivateKey);
        Order.Single memory order = Order.Single({
            expiry: 591951251,
            taker_address: address(swapRouter02ExecutorNew),
            taker_token: address(tokenOut),
            maker_address: payable(
                address(
                    new ERC1271WalletMock(
                        0xdE14f573bA19c82603600651D4672587736Ecf7D
                    )
                )
            ),
            maker_token: address(tokenIn),
            taker_amount: 10860,
            maker_amount: 2710600,
            maker_nonce: 1738726891508,
            receiver: payable(address(swapRouter02ExecutorNew)),
            flags: 0,
            packed_commands: 0
        });

        tokenIn.mint(order.maker_address, 10 ** 18);
        tokenOut.mint(order.taker_address, 10 ** 15);

        // Bebop Approvals
        tokenIn.forceApprove(
            order.maker_address,
            address(bebopTest),
            type(uint256).max
        );

        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);

        Signature.MakerSignature memory makerSigx = Signature.MakerSignature({
            signatureBytes: abi.encodePacked(r, s, v),
            flags: 1
        });

        bytes memory callbackData = abi.encode(
            tokenIn,
            tokenOut,
            order,
            makerSigx,
            0
        );

        return callbackData;
    }

    function testReactorCallback() public {
        uint256 inputAmount = 1;
        uint256 outputAmount = inputAmount;

        uint256 makerPrivateKey = 0x1234123412341234123412341234123412341234123412341234123412341234;
        address makerAddress = vm.addr(makerPrivateKey);

        Order.Single memory order = Order.Single({
            expiry: 980055555,
            taker_address: address(swapRouter02ExecutorNew),
            taker_token: address(tokenOut),
            maker_address: payable(
                address(
                    new ERC1271WalletMock(
                        0xC55F2711B36Fc467a58D7547c8dD8e890703036a
                    )
                )
            ),
            maker_token: address(tokenIn),
            taker_amount: 10 ** 15,
            maker_amount: 2710600,
            maker_nonce: 1738726891508,
            receiver: payable(address(swapRouter02ExecutorNew)),
            flags: 0,
            packed_commands: 0
        });

        // Mint tokens
        tokenIn.mint(order.maker_address, 10 ** 18);
        tokenOut.mint(order.taker_address, 10 ** 15);

        tokenIn.forceApprove(
            order.maker_address,
            address(bebopTest),
            type(uint256).max
        );

        // Capture balances before swap
        uint256 makerTokenInBefore = tokenIn.balanceOf(order.maker_address);
        uint256 takerTokenInBefore = tokenIn.balanceOf(order.taker_address);

        console.log("Before Swap:");
        console.log("Maker TokenIn Balance:", makerTokenInBefore);
        console.log("Taker TokenIn Balance:", takerTokenInBefore);

        ResolvedOrder[] memory resolvedOrders = new ResolvedOrder[](0);
        bytes32 orderHash = keccak256(abi.encode(order));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);

        Signature.MakerSignature memory makerSigx = Signature.MakerSignature({
            signatureBytes: abi.encodePacked(r, s, v),
            flags: 1
        });

        bytes memory callbackData = abi.encode(
            tokenIn,
            tokenOut,
            order,
            makerSigx,
            0
        );

        vm.prank(address(reactor));
        swapRouter02ExecutorNew.reactorCallback(resolvedOrders, callbackData);

        assertEq(tokenIn.balanceOf(order.maker_address), (10 ** 18) - 2710600);
        assertEq(tokenOut.balanceOf(order.maker_address), 10 ** 15);
        assertEq(tokenIn.balanceOf(order.taker_address), 2710600);
        assertEq(tokenOut.balanceOf(order.taker_address), 0);
    }

    function testExclusiveDutchOrderLessThanBebop() public {
        uint256 amountIn = 10245;
        uint256 amountOut = 600;
        address recipient = payable(
            address(
                new ERC1271WalletMock(
                    0xc26D012184eBd826BA1A0f8FcEF059e78868D182
                )
            )
        );
        tokenIn.mint(swapper, 1 ether);

        ExclusiveDutchOrder memory order = ExclusiveDutchOrder({
            info: OrderInfoBuilder
                .init(address(reactor))
                .withSwapper(swapper)
                .withDeadline(block.timestamp + 100),
            decayStartTime: block.timestamp,
            decayEndTime: block.timestamp + 100,
            exclusiveFiller: address(0),
            exclusivityOverrideBps: 300,
            input: DutchInput(tokenIn, amountIn, amountIn),
            outputs: OutputsBuilder.singleDutch(
                tokenIn,
                amountOut * 2,
                amountOut * 2,
                recipient
            )
        });

        bytes memory sig = signOrder(
            swapperPrivateKey,
            address(permit2),
            order
        );
        SignedOrder memory signedOrder = SignedOrder(abi.encode(order), sig);

        vm.prank(address(reactor));
        uint256 takerBalanceBefore = tokenOut.balanceOf(
            address(swapRouter02ExecutorNew)
        );
        swapRouter02ExecutorNew.execute(
            signedOrder,
            createProfitableBebopOrder()
        );
    }

    function testWithdrawETH() public {
        vm.deal(address(swapRouter02ExecutorNew), 1 ether);
        uint256 balanceBefore = address(this).balance;
        swapRouter02ExecutorNew.withdrawETH(address(this));
        uint256 balanceAfter = address(this).balance;
        assertEq(balanceAfter - balanceBefore, 1 ether);
    }

    function testWithdrawNotAuthorized() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(address(0xbeef));
        swapRouter02ExecutorNew.withdrawETH(address(this));
    }

    function testWithdrawArbitraryToken() public {
        tokenIn.mint(address(swapRouter02ExecutorNew), 1000);
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        swapRouter02ExecutorNew.withdrawArbitraryToken(address(this), tokenIn);
        uint256 balanceAfter = tokenIn.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, 1000);
    }

    function testAddWhitelistedCallerByOwner() public {
        address newWhitelist = makeAddr("newwhitelist");
        swapRouter02ExecutorNew.addWhitelistedCaller(newWhitelist);
        bool isWhiteListed = swapRouter02ExecutorNew.isWhitelisted(
            newWhitelist
        );
        assertTrue(isWhiteListed);
    }

    function testAddWhitelistDuplicate() public {
        vm.expectRevert("Address is already whitelisted");
        swapRouter02ExecutorNew.addWhitelistedCaller(address(this));
    }

    function testAddWhitelistedCallerByNonOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert("UNAUTHORIZED");
        swapRouter02ExecutorNew.addWhitelistedCaller(address(0xbeef));
    }

    function testRemoveWhitelistedCallerByNonOwner() public {
        address newWhitelist = makeAddr("newwhitelist");

        swapRouter02ExecutorNew.addWhitelistedCaller(newWhitelist);

        bool isWhiteListedBefore = swapRouter02ExecutorNew.isWhitelisted(
            newWhitelist
        );
        assertTrue(isWhiteListedBefore);

        vm.prank(address(0xbeef));

        vm.expectRevert("UNAUTHORIZED");
        swapRouter02ExecutorNew.removeWhitelistedCaller(newWhitelist);

        bool isWhiteListedAfter = swapRouter02ExecutorNew.isWhitelisted(
            newWhitelist
        );
        assertTrue(isWhiteListedAfter);
    }

    function testRemoveWhitelistedCallerByOwner() public {
        address newWhitelist = makeAddr("newwhitelist");
        swapRouter02ExecutorNew.addWhitelistedCaller(newWhitelist);

        bool isWhiteListedBefore = swapRouter02ExecutorNew.isWhitelisted(
            newWhitelist
        );
        assertTrue(isWhiteListedBefore);

        swapRouter02ExecutorNew.removeWhitelistedCaller(newWhitelist);

        bool isWhiteListedAfter = swapRouter02ExecutorNew.isWhitelisted(
            newWhitelist
        );
        assertFalse(isWhiteListedAfter);
    }

    function testRemoveNonWhitelistedCaller() public {
        address nonExistentAddress = makeAddr("nonexistent");

        vm.expectRevert("Address not found in whitelist");
        swapRouter02ExecutorNew.removeWhitelistedCaller(nonExistentAddress);
    }
}
