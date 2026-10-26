// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {BraboDice} from "../src/BraboDice.sol";
import {IVRFSubscriptionV2Plus} from
    "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol";

/// @notice Deploys BraboDice on Base mainnet and registers it as a consumer
///         on an existing, already-funded VRF v2.5 subscription.
///
/// Prerequisites (do these on https://vrf.chain.link before running this script):
///   1. Create a VRF v2.5 subscription on Base mainnet.
///   2. Fund it with LINK.
///   3. Have the subscription owner's private key available — it must be the
///      same account broadcasting this script, since step 2 below calls
///      addConsumer(), which only the subscription owner may call.
///
/// Required env vars:
///   PRIVATE_KEY      - deployer / subscription-owner private key
///   SUBSCRIPTION_ID  - the uint256 subscription ID from vrf.chain.link
///
/// Usage:
///   forge script script/DeployBraboDice.s.sol:DeployBraboDice \
///     --rpc-url <base_mainnet_rpc_url> \
///     --broadcast \
///     --verify
contract DeployBraboDice is Script {
    // Base mainnet, VRF v2.5 (verify against https://docs.chain.link/vrf/v2-5/supported-networks
    // before deploying — these must be exact).
    address constant VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;

    // 30 gwei gas lane key hash on Base mainnet.
    bytes32 constant KEY_HASH = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;

    function run() external returns (BraboDice braboDice) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 subscriptionId = vm.envUint("SUBSCRIPTION_ID");

        vm.startBroadcast(deployerPrivateKey);

        braboDice = new BraboDice(VRF_COORDINATOR, subscriptionId, KEY_HASH);

        IVRFSubscriptionV2Plus(VRF_COORDINATOR).addConsumer(subscriptionId, address(braboDice));

        vm.stopBroadcast();

        console.log("BraboDice deployed at:", address(braboDice));
        console.log("Registered as consumer on subscription:", subscriptionId);
    }
}
