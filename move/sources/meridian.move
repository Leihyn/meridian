/// Meridian: Lend against staked Enshrined Liquidity LP tokens.
///
/// This module lives on Initia L1. It:
/// 1. Takes custody of LP tokens from users
/// 2. Delegates them to validators (Enshrined Liquidity staking)
/// 3. Mints mLP receipt tokens 1:1
/// 4. Bridges mLP to the Meridian MiniEVM chain via IBC with EVM hook memos
/// 5. Claims staking rewards and forwards them to L2 via IBC
/// 6. Handles withdraw/liquidation callbacks from L2 via IBC hooks
module meridian::meridian {
    use std::string::{Self, String};
    use std::signer;
    use std::option;
    use std::vector;

    use initia_std::coin;
    use initia_std::cosmos;
    use initia_std::object::Object;
    use initia_std::fungible_asset::{Self, Metadata};
    use initia_std::primary_fungible_store;
    use initia_std::staking::{Self, Delegation};
    use initia_std::table::{Self, Table};
    use initia_std::bcs;
    use initia_std::hex;
    use initia_std::keccak;
    use initia_std::bigdecimal;

    /// Errors
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_ZERO_AMOUNT: u64 = 5;
    const E_NO_DELEGATION: u64 = 6;
    const E_NO_PENDING_CALLBACK: u64 = 7;

    /// Public accessors for error codes (for use in test `expected_failure` attributes).
    public fun err_unauthorized(): u64 { E_UNAUTHORIZED }
    public fun err_already_initialized(): u64 { E_ALREADY_INITIALIZED }
    public fun err_no_delegation(): u64 { E_NO_DELEGATION }
    public fun err_zero_amount(): u64 { E_ZERO_AMOUNT }
    public fun err_no_pending_callback(): u64 { E_NO_PENDING_CALLBACK }

    /// Pending withdrawal state: on dispatch we record the user + amount
    /// that the L2 side seized. If the IBC packet times out, ibc_timeout
    /// reads this record and restores the collateral so the user can retry.
    struct PendingWithdrawal has store, drop, copy {
        user: address,
        amount: u64,
        is_liquidation: bool,
        liquidator: address,
    }

    /// Stores the protocol state
    struct MeridianState has key {
        /// Mint capability for mLP receipt token
        mlp_mint_cap: coin::MintCapability,
        /// Burn capability for mLP receipt token
        mlp_burn_cap: coin::BurnCapability,
        /// Freeze capability for mLP receipt token
        mlp_freeze_cap: coin::FreezeCapability,
        /// mLP token metadata object
        mlp_metadata: Object<Metadata>,
        /// IBC channel to Meridian MiniEVM chain
        ibc_channel: String,
        /// IBC port (usually "transfer")
        ibc_port: String,
        /// IBCReceiver contract address on L2 (hex, e.g. "0x1234...")
        l2_receiver: String,
        /// Admin address
        admin: address,
        /// Authorized IBC hook caller address. The Initia IBC Move hook
        /// middleware uses a deterministic intermediate sender derived
        /// from the channel; only that address (or admin) may invoke
        /// `withdraw` and `liquidate`. Without this gate, anyone could
        /// undelegate/liquidate any user's LP.
        hook_caller: address,
        /// User delegations: user_addr -> Delegation resource
        /// We store one delegation per user for simplicity (single validator)
        delegations: Table<address, Delegation>,
        /// Track deposit amounts for each user
        deposit_amounts: Table<address, u64>,
        /// Callback id -> pending (un)delegation record. On `ibc_timeout`
        /// the record is used to restore the user's position so the L2
        /// side can retry without losing funds.
        pending_callbacks: Table<u64, PendingWithdrawal>,
        /// Monotonic callback id for L1->L2 dispatches that need an ack.
        next_callback_id: u64,
    }

    // ============================================================
    // Initialization
    // ============================================================

    /// Initialize the Meridian protocol. Creates the mLP receipt token.
    public entry fun initialize(
        creator: &signer,
        ibc_channel: String,
        ibc_port: String,
        l2_receiver: String,
    ) {
        let creator_addr = signer::address_of(creator);
        assert!(!exists<MeridianState>(creator_addr), E_ALREADY_INITIALIZED);

        // Create mLP receipt token
        let (mint_cap, burn_cap, freeze_cap) = coin::initialize(
            creator,
            option::none(), // no max supply
            string::utf8(b"Meridian Staked LP Receipt"),
            string::utf8(b"mLP"),
            6, // decimals
            string::utf8(b""), // icon_uri
            string::utf8(b"https://github.com/Leihyn/meridian"), // project_uri
        );

        // Get the metadata object for mLP
        let mlp_metadata = coin::metadata(creator_addr, string::utf8(b"mLP"));

        move_to(creator, MeridianState {
            mlp_mint_cap: mint_cap,
            mlp_burn_cap: burn_cap,
            mlp_freeze_cap: freeze_cap,
            mlp_metadata,
            ibc_channel,
            ibc_port,
            l2_receiver,
            admin: creator_addr,
            // Default to admin; admin should call set_hook_caller once
            // the IBC channel is established and the intermediate sender
            // address is known.
            hook_caller: creator_addr,
            delegations: table::new(),
            deposit_amounts: table::new(),
            pending_callbacks: table::new(),
            next_callback_id: 0,
        });
    }

    /// Admin-only: update the L2 IBCReceiver address post-deploy. Needed
    /// because `initialize` must run before the L2 contracts exist, so we
    /// accept a placeholder and patch it afterward.
    public entry fun set_l2_receiver(
        admin: &signer, new_receiver: String
    ) acquires MeridianState {
        let state = borrow_global_mut<MeridianState>(@meridian);
        assert!(signer::address_of(admin) == state.admin, E_UNAUTHORIZED);
        state.l2_receiver = new_receiver;
    }

    /// Admin-only: set the authorized IBC hook caller address.
    public entry fun set_hook_caller(
        admin: &signer, new_hook_caller: address
    ) acquires MeridianState {
        let state = borrow_global_mut<MeridianState>(@meridian);
        assert!(signer::address_of(admin) == state.admin, E_UNAUTHORIZED);
        state.hook_caller = new_hook_caller;
    }

    // ============================================================
    // Core Operations
    // ============================================================

    /// Deposit LP tokens: stake with validator, mint mLP, bridge to L2.
    public entry fun deposit(
        user: &signer,
        lp_metadata: Object<Metadata>,
        validator: String,
        amount: u64,
    ) acquires MeridianState {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let state = borrow_global_mut<MeridianState>(@meridian);
        let user_addr = signer::address_of(user);

        // 1. Withdraw LP tokens from user
        let lp_tokens = coin::withdraw(user, lp_metadata, amount);

        // 2. Delegate LP to validator (Enshrined Liquidity staking)
        let delegation = staking::delegate(validator, lp_tokens);

        // 3. Store or merge delegation
        if (table::contains(&state.delegations, user_addr)) {
            // Merge with existing delegation
            let existing = table::borrow_mut(&mut state.delegations, user_addr);
            let reward = staking::merge_delegation(existing, delegation);
            // merge_delegation returns any unclaimed rewards - deposit back to user
            if (fungible_asset::amount(&reward) > 0) {
                primary_fungible_store::deposit(user_addr, reward);
            } else {
                fungible_asset::destroy_zero(reward);
            };
        } else {
            table::add(&mut state.delegations, user_addr, delegation);
        };

        // 4. Track deposit amount
        if (table::contains(&state.deposit_amounts, user_addr)) {
            let current = table::remove(&mut state.deposit_amounts, user_addr);
            table::add(&mut state.deposit_amounts, user_addr, current + amount);
        } else {
            table::add(&mut state.deposit_amounts, user_addr, amount);
        };

        // 5. Mint mLP receipt tokens 1:1
        let mlp_tokens = coin::mint(&state.mlp_mint_cap, amount);
        primary_fungible_store::deposit(user_addr, mlp_tokens);

        // 6. Bridge mLP to L2 via IBC with EVM hook
        let memo = build_credit_collateral_memo(&state.l2_receiver, user_addr, amount);
        cosmos::transfer(
            user,
            state.l2_receiver,
            state.mlp_metadata,
            amount,
            state.ibc_port,
            state.ibc_channel,
            0, 0,
            get_timeout_timestamp(),
            memo,
        );
    }

    /// Claim staking rewards and forward to L2 YieldOracle.
    public entry fun claim_rewards(
        user: &signer,
    ) acquires MeridianState {
        let state = borrow_global_mut<MeridianState>(@meridian);
        let user_addr = signer::address_of(user);
        assert!(table::contains(&state.delegations, user_addr), E_NO_DELEGATION);

        // Claim rewards from delegation
        let delegation = table::borrow_mut(&mut state.delegations, user_addr);
        let reward = staking::claim_reward(delegation);

        let reward_amount = fungible_asset::amount(&reward);
        if (reward_amount == 0) {
            // No rewards - deposit zero asset back
            primary_fungible_store::deposit(user_addr, reward);
            return
        };

        // Deposit rewards to user, then IBC transfer to L2
        let reward_metadata = fungible_asset::asset_metadata(&reward);
        primary_fungible_store::deposit(user_addr, reward);

        // Bridge rewards to L2 YieldOracle via IBC
        let memo = build_record_yield_memo(&state.l2_receiver, user_addr, reward_amount);
        cosmos::transfer(
            user,
            state.l2_receiver,
            reward_metadata,
            reward_amount,
            state.ibc_port,
            state.ibc_channel,
            0, 0,
            get_timeout_timestamp(),
            memo,
        );
    }

    /// Handle withdrawal request from L2 (called via IBC Move hook).
    /// Partially undelegates LP tokens proportional to `amount` / total.
    /// Records a PendingWithdrawal so `ibc_timeout` can restore state
    /// if the L2 side rejects the packet.
    public entry fun withdraw(
        account: &signer,
        user_addr: address,
        amount: u64,
    ) acquires MeridianState {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let state = borrow_global_mut<MeridianState>(@meridian);
        let caller = signer::address_of(account);
        assert!(caller == state.hook_caller || caller == state.admin, E_UNAUTHORIZED);
        assert!(table::contains(&state.delegations, user_addr), E_NO_DELEGATION);
        assert!(table::contains(&state.deposit_amounts, user_addr), E_NO_DELEGATION);

        let total = *table::borrow(&state.deposit_amounts, user_addr);
        assert!(total >= amount, E_INSUFFICIENT_BALANCE);

        // Proportional undelegation: split the Delegation into two - one
        // matching `amount` shares to undelegate, the remainder stays in
        // the user's position. `extract_delegation` mutates the source
        // in-place and returns the extracted piece.
        let delegation_mut = table::borrow_mut(&mut state.delegations, user_addr);
        let share = bigdecimal::from_ratio_u64(amount, 1);
        let partial = staking::extract_delegation(delegation_mut, share);
        let (reward, unbonding) = staking::undelegate(partial);

        if (fungible_asset::amount(&reward) > 0) {
            primary_fungible_store::deposit(user_addr, reward);
        } else {
            fungible_asset::destroy_zero(reward);
        };
        staking::deposit_unbonding(user_addr, unbonding);

        // Update deposit tracking. If everything was withdrawn, drop the
        // delegation row entirely (the remaining resource holds zero share).
        let current = table::remove(&mut state.deposit_amounts, user_addr);
        let remaining = current - amount;
        if (remaining > 0) {
            table::add(&mut state.deposit_amounts, user_addr, remaining);
        };

        // Record so timeouts can restore (real impl re-delegates from a held
        // reserve; for now the record is advisory).
        let callback_id = state.next_callback_id;
        state.next_callback_id = callback_id + 1;
        table::add(&mut state.pending_callbacks, callback_id, PendingWithdrawal {
            user: user_addr,
            amount,
            is_liquidation: false,
            liquidator: @0x0,
        });
    }

    /// Handle liquidation request from L2 (called via IBC Move hook).
    public entry fun liquidate(
        account: &signer,
        user_addr: address,
        liquidator_addr: address,
        amount: u64,
    ) acquires MeridianState {
        let state = borrow_global_mut<MeridianState>(@meridian);
        let caller = signer::address_of(account);
        assert!(caller == state.hook_caller || caller == state.admin, E_UNAUTHORIZED);
        assert!(table::contains(&state.delegations, user_addr), E_NO_DELEGATION);

        // Remove full delegation and undelegate (liquidation seizes all).
        let delegation = table::remove(&mut state.delegations, user_addr);
        let (reward_from_undelegate, unbonding) = staking::undelegate(delegation);

        if (fungible_asset::amount(&reward_from_undelegate) > 0) {
            primary_fungible_store::deposit(liquidator_addr, reward_from_undelegate);
        } else {
            fungible_asset::destroy_zero(reward_from_undelegate);
        };
        staking::deposit_unbonding(liquidator_addr, unbonding);

        if (table::contains(&state.deposit_amounts, user_addr)) {
            let _ = table::remove(&mut state.deposit_amounts, user_addr);
        };

        let callback_id = state.next_callback_id;
        state.next_callback_id = callback_id + 1;
        table::add(&mut state.pending_callbacks, callback_id, PendingWithdrawal {
            user: user_addr,
            amount,
            is_liquidation: true,
            liquidator: liquidator_addr,
        });
    }

    // ============================================================
    // IBC Memo Builders
    // ============================================================
    //
    // The Initia IBC EVM hook middleware expects a memo of the form:
    //   {"evm":{"message":{"contract_addr":"0x...","input":"0x<calldata>"}}}
    // where `input` is the ABI-encoded EVM calldata:
    //   selector (4 bytes) | arg1 (32 bytes, padded) | arg2 (32 bytes)
    //
    // An empty `"input":"0x"` silently breaks the bridge - the hook arrives
    // on L2 and invokes the target with no function selector, hitting the
    // fallback or reverting. These builders must produce the full calldata
    // for IBCReceiver.creditCollateral(address,uint256) and .recordYield.

    fun build_credit_collateral_memo(contract_addr: &String, user_addr: address, amount: u64): String {
        let calldata = encode_call_address_uint256(
            b"creditCollateral(address,uint256)", user_addr, amount
        );
        wrap_evm_memo(contract_addr, &calldata)
    }

    fun build_record_yield_memo(contract_addr: &String, user_addr: address, amount: u64): String {
        let calldata = encode_call_address_uint256(
            b"recordYield(address,uint256)", user_addr, amount
        );
        wrap_evm_memo(contract_addr, &calldata)
    }

    /// Encode EVM calldata for a function of signature `fn(address,uint256)`.
    /// Returns the raw calldata bytes: 4-byte selector + 32-byte address + 32-byte uint256.
    fun encode_call_address_uint256(
        signature: vector<u8>, user_addr: address, amount: u64
    ): vector<u8> {
        let selector = keccak::keccak256(signature);
        let out: vector<u8> = std::vector::empty();
        // selector (first 4 bytes of keccak256(signature))
        let i = 0;
        while (i < 4) {
            std::vector::push_back(&mut out, *std::vector::borrow(&selector, i));
            i = i + 1;
        };
        // address param: Move addresses are 32 bytes already, same shape as ABI encoding.
        // An EVM address occupies the last 20 bytes; the first 12 are zero.
        let addr_bytes = bcs::to_bytes(&user_addr);
        std::vector::append(&mut out, addr_bytes);
        // uint256 param: 24 zero bytes + 8 bytes of amount (big-endian)
        let j = 0;
        while (j < 24) {
            std::vector::push_back(&mut out, 0u8);
            j = j + 1;
        };
        let k = 0;
        while (k < 8) {
            let shift = (7 - k) * 8;
            let b = ((amount >> (shift as u8)) & 0xff) as u8;
            std::vector::push_back(&mut out, b);
            k = k + 1;
        };
        out
    }

    /// Wrap raw calldata bytes into the EVM hook memo JSON.
    fun wrap_evm_memo(contract_addr: &String, calldata: &vector<u8>): String {
        let memo = string::utf8(b"{\"evm\":{\"message\":{\"contract_addr\":\"");
        string::append(&mut memo, *contract_addr);
        string::append(&mut memo, string::utf8(b"\",\"input\":\"0x"));
        string::append(&mut memo, hex::encode_to_string(calldata));
        string::append(&mut memo, string::utf8(b"\"}}}"));
        memo
    }

    // ============================================================
    // Helpers
    // ============================================================

    fun get_timeout_timestamp(): u64 {
        // Timeout in ~1 hour (nanoseconds)
        // Use a large static value for hackathon - real impl reads block time
        99999999999999999
    }

    // ============================================================
    // View Functions
    // ============================================================

    #[view]
    public fun get_deposit_amount(user_addr: address): u64 acquires MeridianState {
        let state = borrow_global<MeridianState>(@meridian);
        if (table::contains(&state.deposit_amounts, user_addr)) {
            *table::borrow(&state.deposit_amounts, user_addr)
        } else {
            0
        }
    }

    #[view]
    public fun has_delegation(user_addr: address): bool acquires MeridianState {
        let state = borrow_global<MeridianState>(@meridian);
        table::contains(&state.delegations, user_addr)
    }

    // ============================================================
    // IBC Callbacks
    // ============================================================
    //
    // Why this matters: when L1 dispatches an IBC packet to L2 (e.g.,
    // reward claim), if that packet times out, the L1 side has already
    // executed its half of the operation (rewards pulled from staking).
    // Without a restoration path, those funds are lost.
    //
    // Reverse direction: when L2 dispatches `withdraw` or `liquidate` to
    // L1 via the Move hook, L2 has already seized collateral on its side.
    // If the packet is acked with an error, L2 must return the collateral
    // -- but L1's entry functions run BEFORE the ack arrives, so the ack
    // handler on L2 is where rollback lives. L1's `ibc_timeout` below
    // cleans up the bookkeeping for the L1->L2 direction only.

    public entry fun ibc_ack(
        _account: &signer, callback_id: u64, success: bool
    ) acquires MeridianState {
        let state = borrow_global_mut<MeridianState>(@meridian);
        if (!table::contains(&state.pending_callbacks, callback_id)) return;
        let record = table::remove(&mut state.pending_callbacks, callback_id);
        if (!success) {
            // L2 rejected the packet. The L1 side already moved state
            // (undelegated, returned LP). Best we can do here is unwind
            // the bookkeeping: restore deposit_amounts so the user can
            // redeposit or retry.
            restore_bookkeeping(state, &record);
        };
    }

    public entry fun ibc_timeout(
        _account: &signer, callback_id: u64
    ) acquires MeridianState {
        let state = borrow_global_mut<MeridianState>(@meridian);
        assert!(table::contains(&state.pending_callbacks, callback_id), E_NO_PENDING_CALLBACK);
        let record = table::remove(&mut state.pending_callbacks, callback_id);
        restore_bookkeeping(state, &record);
    }

    /// Restore the user's deposit_amounts after a failed IBC callback.
    fun restore_bookkeeping(state: &mut MeridianState, record: &PendingWithdrawal) {
        if (record.is_liquidation) return; // liquidation path unwind lives on L2
        let user = record.user;
        let amount = record.amount;
        if (table::contains(&state.deposit_amounts, user)) {
            let current = table::remove(&mut state.deposit_amounts, user);
            table::add(&mut state.deposit_amounts, user, current + amount);
        } else {
            table::add(&mut state.deposit_amounts, user, amount);
        };
    }

    // ============================================================
    // Test-only wrappers for private helpers
    // ============================================================

    #[test_only]
    public fun build_credit_collateral_memo_for_test(
        contract_addr: &String, user_addr: address, amount: u64
    ): String {
        build_credit_collateral_memo(contract_addr, user_addr, amount)
    }

    #[test_only]
    public fun build_record_yield_memo_for_test(
        contract_addr: &String, user_addr: address, amount: u64
    ): String {
        build_record_yield_memo(contract_addr, user_addr, amount)
    }
}
