// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {IReactor} from "../interfaces/IReactor.sol";
import {CurrencyLibrary} from "../lib/CurrencyLibrary.sol";
import {ResolvedOrder, SignedOrder} from "../base/ReactorStructs.sol";
import {Order} from "BebopSettlement/src/libs/Order.sol";
import {Signature} from "BebopSettlement/src/libs/Signature.sol";
import {ISwapRouter02} from "../external/ISwapRouter02.sol";
import {IBebopSettlement} from "BebopSettlement/src/interface/IBebopSettlement.sol";
import {Transfer} from "BebopSettlement/src/libs/Transfer.sol";

/// @notice A fill contract that uses SwapRouter02 to execute trades
contract SwapRouter02ExecutorNew is IReactorCallback, Owned {
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for address;

    /// @notice thrown if reactorCallback is called with a non-whitelisted filler
    error CallerNotWhitelisted();
    /// @notice thrown if reactorCallback is called by an address other than the reactor
    error MsgSenderNotReactor();

    ISwapRouter02 private immutable swapRouter02;
    IBebopSettlement private immutable bebop;
    address[] private whitelistedCallers;
    IReactor private immutable reactor;
    WETH private immutable weth;

    modifier onlyWhitelistedCaller() {
        bool isWhitelisted = false;
        for (uint256 i = 0; i < whitelistedCallers.length; i++) {
            if (msg.sender == whitelistedCallers[i]) {
                isWhitelisted = true;
                break;
            }
        }
        if (!isWhitelisted) {
            revert CallerNotWhitelisted();
        }
        _;
    }

    modifier onlyReactor() {
        if (msg.sender != address(reactor)) {
            revert MsgSenderNotReactor();
        }
        _;
    }

    constructor(
        address _whitelistedCaller,
        IReactor _reactor,
        address _owner,
        ISwapRouter02 _swapRouter02,
        IBebopSettlement _bebop
    ) Owned(_owner) {
        whitelistedCallers.push(_whitelistedCaller);
        reactor = _reactor;
        swapRouter02 = _swapRouter02;
        bebop = _bebop;
        weth = WETH(payable(_swapRouter02.WETH9()));
    }

    /// @notice Add a new whitelisted caller. Only callable by the owner.
    /// @param newCaller The address to add to the whitelist.
    function addWhitelistedCaller(address newCaller) external onlyOwner {
        for (uint256 i = 0; i < whitelistedCallers.length; i++) {
            if (whitelistedCallers[i] == newCaller) {
                revert("Address is already whitelisted");
            }
        }
        whitelistedCallers.push(newCaller);
    }

    /// @notice Remove a whitelisted caller. Only callable by the owner.
    /// @param callerToRemove The address to remove from the whitelist.
    function removeWhitelistedCaller(
        address callerToRemove
    ) external onlyOwner {
        uint256 indexToRemove = type(uint256).max;

        for (uint256 i = 0; i < whitelistedCallers.length; i++) {
            if (whitelistedCallers[i] == callerToRemove) {
                indexToRemove = i;
                break;
            }
        }

        if (indexToRemove == type(uint256).max) {
            revert("Address not found in whitelist");
        }

        whitelistedCallers[indexToRemove] = whitelistedCallers[
            whitelistedCallers.length - 1
        ];
        whitelistedCallers.pop();
    }

    /// @notice Check if an address is whitelisted.
    /// @param caller The address to check if it's whitelisted.
    /// @return True if the address is whitelisted, otherwise false.
    function isWhitelisted(address caller) external view returns (bool) {
        for (uint256 i = 0; i < whitelistedCallers.length; i++) {
            if (whitelistedCallers[i] == caller) {
                return true;
            }
        }
        return false;
    }

    /// @notice Execute a trade using a signed order. Only callable by a whitelisted caller.
    function execute(
        SignedOrder calldata order,
        bytes calldata callbackData
    ) external onlyWhitelistedCaller {
        reactor.executeWithCallback(order, callbackData);
    }

    /// @notice Execute a batch of trades using signed orders. Only callable by a whitelisted caller.
    function executeBatch(
        SignedOrder[] calldata orders,
        bytes calldata callbackData
    ) external onlyWhitelistedCaller {
        reactor.executeBatchWithCallback(orders, callbackData);
    }

    function reactorCallback(
        ResolvedOrder[] calldata orders,
        bytes calldata callbackData
    ) external onlyReactor {
        (
            address tokenIn,
            address tokenOut,
            Order.Single memory order,
            Signature.MakerSignature memory makerSigx,
            uint256 filledTakerAmount
        ) = abi.decode(
                callbackData,
                (
                    address,
                    address,
                    Order.Single,
                    Signature.MakerSignature,
                    uint256
                )
            );

        ERC20(tokenIn).safeApprove(address(bebop), type(uint256).max);
        ERC20(tokenOut).safeApprove(address(bebop), type(uint256).max);

        ERC20(tokenIn).safeApprove(address(this), type(uint256).max);
        ERC20(tokenOut).safeApprove(address(this), type(uint256).max);

        ERC20(tokenIn).safeApprove(address(reactor), type(uint256).max);

        bebop.swapSingle(order, makerSigx, filledTakerAmount);

        // leftover logic
        if (orders.length > 0) {
            uint256 dutchOrderAmount = orders[0].input.amount;
            uint256 bebopTakerAmount = order.taker_amount;

            if (bebopTakerAmount > dutchOrderAmount) {
                uint256 leftoverPositiveAmount = bebopTakerAmount -
                    dutchOrderAmount;
                ERC20(order.taker_token).transferFrom(
                    order.taker_address,
                    address(this),
                    leftoverPositiveAmount
                );
            }

            if (dutchOrderAmount > bebopTakerAmount) {
                uint256 leftoverNegativeAmount = dutchOrderAmount -
                    bebopTakerAmount;
                ERC20(order.taker_token).transfer(
                    order.taker_address,
                    leftoverNegativeAmount
                );
            }
        }
    }

    /// @notice This function can be used to convert ERC20s to ETH that remains in this contract
    /// @param tokensToApprove Max approve these tokens to swapRouter02
    /// @param multicallData Pass into swapRouter02.multicall()
    function multicall(
        ERC20[] calldata tokensToApprove,
        bytes[] calldata multicallData
    ) external onlyOwner {
        for (uint256 i = 0; i < tokensToApprove.length; i++) {
            tokensToApprove[i].safeApprove(
                address(swapRouter02),
                type(uint256).max
            );
        }
        swapRouter02.multicall(type(uint256).max, multicallData);
    }

    /// @notice Unwraps the contract's WETH9 balance and sends it to the recipient as ETH. Can only be called by owner.
    /// @param recipient The address receiving ETH
    function unwrapWETH(address recipient) external onlyOwner {
        uint256 balanceWETH = weth.balanceOf(address(this));

        weth.withdraw(balanceWETH);
        SafeTransferLib.safeTransferETH(recipient, address(this).balance);
    }

    /// @notice Transfer all ETH in this contract to the recipient. Can only be called by owner.
    /// @param recipient The recipient of the ETH
    function withdrawETH(address recipient) external onlyOwner {
        SafeTransferLib.safeTransferETH(recipient, address(this).balance);
    }

    /// @notice Transfer all token in this contract to the recipient. Can only be called by owner.
    /// @param recipient The recipient of the token
    /// @param token The ERC20 token to withdraw
    function withdrawArbitraryToken(
        address recipient,
        ERC20 token
    ) external onlyOwner {
        SafeTransferLib.safeTransferFrom(
            token,
            address(this),
            recipient,
            token.balanceOf(address(this))
        );
    }

    /// @notice Necessary for this contract to receive ETH when calling unwrapWETH()
    receive() external payable {}
}
