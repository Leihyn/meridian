#[test_only]
module meridian::meridian_tests {
    use std::string::{Self, String};
    use std::signer;

    use initia_std::account;
    use initia_std::coin;
    use initia_std::staking;
    use initia_std::bigdecimal;
    use initia_std::primary_fungible_store;

    use meridian::meridian;

    // ============================================================
    // Setup
    // ============================================================

    const ADMIN: address = @meridian;
    const USER: address = @0xBEEF;
    const ATTACKER: address = @0xBAD;
    const LIQUIDATOR: address = @0xC0FFEE;

    #[test_only]
    fun init_meridian(admin: &signer) {
        // Bootstrap the fungible asset infra before the module tries to
        // create the mLP coin.
        primary_fungible_store::init_module_for_test();
        meridian::initialize(
            admin,
            string::utf8(b"channel-0"),
            string::utf8(b"transfer"),
            string::utf8(b"0x47D11C25C326084F4206DA7A420D6FB7D0FC0992"),
        );
    }

    // ============================================================
    // 1. MEMO FORMAT - the critical bridge bug
    // ============================================================
    //
    // The L1 memo must tell the IBC EVM hook middleware how to call
    // IBCReceiver.creditCollateral(address user, uint256 amount) on L2.
    // The middleware expects:
    //   {"evm":{"message":{"contract_addr":"0x...","input":"0x<calldata>"}}}
    // where `input` is the ABI-encoded calldata:
    //   selector (4 bytes) | user (32 bytes) | amount (32 bytes)
    // = 68 bytes = 136 hex chars, plus the "0x" prefix = 138 chars.
    //
    // An empty input ("0x") is a broken bridge - the hook arrives and
    // calls the target with no function selector, hitting fallback or
    // reverting. This test enforces the calldata is non-empty and
    // well-formed. It FAILS against the original memo builders.

    // Expected selectors (from Solidity: `cast sig "creditCollateral(address,uint256)"`)
    // creditCollateral(address,uint256) = 0x2ef35002
    // recordYield(address,uint256)      = 0x669e1bb6
    // These MUST match what the L2 IBCReceiver decodes, or the bridge is broken.

    #[test(admin = @meridian)]
    fun test_credit_collateral_memo_has_abi_calldata(admin: &signer) {
        init_meridian(admin);

        let memo = meridian::build_credit_collateral_memo_for_test(
            &string::utf8(b"0x47D11C25C326084F4206DA7A420D6FB7D0FC0992"),
            USER,
            1000,
        );

        // Structural checks
        let memo_bytes = *string::bytes(&memo);
        assert!(contains_substring(&memo_bytes, b"\"evm\""), 1);
        assert!(contains_substring(&memo_bytes, b"\"contract_addr\""), 2);
        assert!(!contains_substring(&memo_bytes, b"\"input\":\"0x\"}}}"), 3); // not empty

        // Calldata sanity: selector(8 hex) + address(64 hex) + uint256(64 hex) = 136
        let input_hex = extract_input_hex(&memo);
        assert!(string::length(&input_hex) == 136, 4);

        // Selector must match Solidity keccak256("creditCollateral(address,uint256)")[0..4]
        let expected_selector = string::utf8(b"2ef35002");
        assert!(starts_with(&input_hex, &expected_selector), 5);

        // Amount field: last 64 hex chars. 1000 = 0x3e8, padded to 32 bytes.
        let amount_hex = substring(&input_hex, 72, 136);
        assert!(amount_hex == string::utf8(
            b"00000000000000000000000000000000000000000000000000000000000003e8"
        ), 6);
    }

    #[test(admin = @meridian)]
    fun test_record_yield_memo_has_abi_calldata(admin: &signer) {
        init_meridian(admin);

        let memo = meridian::build_record_yield_memo_for_test(
            &string::utf8(b"0x47D11C25C326084F4206DA7A420D6FB7D0FC0992"),
            USER,
            500,
        );

        let input_hex = extract_input_hex(&memo);
        assert!(string::length(&input_hex) == 136, 1);

        // Selector = keccak256("recordYield(address,uint256)")[0..4]
        assert!(starts_with(&input_hex, &string::utf8(b"669e1bb6")), 2);

        // 500 = 0x1f4
        let amount_hex = substring(&input_hex, 72, 136);
        assert!(amount_hex == string::utf8(
            b"00000000000000000000000000000000000000000000000000000000000001f4"
        ), 3);
    }

    // ============================================================
    // 2. L1 AUTH - unauthorized withdraw/liquidate
    // ============================================================
    //
    // withdraw() and liquidate() are entry points called by the IBC
    // Move hook middleware. The `_account` signer represents the
    // intermediate sender. Without verifying it, anyone can call
    // these entries and steal/liquidate any user's LP.
    //
    // These tests assert that an unrelated signer CANNOT invoke
    // withdraw/liquidate. They FAIL against the original code.

    #[test(admin = @meridian, attacker = @0xBAD)]
    #[expected_failure(abort_code = 4, location = meridian::meridian)]
    fun test_withdraw_unauthorized(admin: &signer, attacker: &signer) {
        init_meridian(admin);
        // The attacker tries to call withdraw on behalf of USER.
        // After fix, this must abort with E_UNAUTHORIZED.
        meridian::withdraw(attacker, USER, 1000);
    }

    #[test(admin = @meridian, attacker = @0xBAD)]
    #[expected_failure(abort_code = 4, location = meridian::meridian)]
    fun test_liquidate_unauthorized(admin: &signer, attacker: &signer) {
        init_meridian(admin);
        meridian::liquidate(attacker, USER, LIQUIDATOR, 1000);
    }

    // ============================================================
    // 3. VIEW FUNCTIONS
    // ============================================================

    #[test(admin = @meridian)]
    fun test_initial_view_state(admin: &signer) {
        init_meridian(admin);
        assert!(meridian::get_deposit_amount(USER) == 0, 1);
        assert!(!meridian::has_delegation(USER), 2);
    }

    #[test(admin = @meridian)]
    #[expected_failure(abort_code = 2, location = meridian::meridian)]
    fun test_double_initialize_fails(admin: &signer) {
        init_meridian(admin);
        init_meridian(admin); // must abort
    }

    // ============================================================
    // 4. IBC CALLBACKS (no-op sanity)
    // ============================================================

    #[test(admin = @meridian)]
    fun test_ibc_ack_no_record_is_noop(admin: &signer) {
        init_meridian(admin);
        // ack for an unknown callback id silently returns (no pending state
        // to restore). This preserves replay safety.
        meridian::ibc_ack(admin, 42, true);
        meridian::ibc_ack(admin, 42, false);
    }

    #[test(admin = @meridian)]
    #[expected_failure(abort_code = 7, location = meridian::meridian)]
    fun test_ibc_timeout_without_pending_record_aborts(admin: &signer) {
        init_meridian(admin);
        // timeout on an unknown callback MUST abort - silently ignoring a
        // timeout masks state desyncs. The pending-callback check is the
        // forensic trail for post-mortem.
        meridian::ibc_timeout(admin, 99);
    }

    // ============================================================
    // Helpers
    // ============================================================

    fun starts_with(s: &String, prefix: &String): bool {
        let sb = string::bytes(s);
        let pb = string::bytes(prefix);
        let slen = std::vector::length(sb);
        let plen = std::vector::length(pb);
        if (plen > slen) return false;
        let i = 0;
        while (i < plen) {
            if (*std::vector::borrow(sb, i) != *std::vector::borrow(pb, i)) return false;
            i = i + 1;
        };
        true
    }

    fun substring(s: &String, start: u64, end: u64): String {
        let sb = string::bytes(s);
        let out: vector<u8> = std::vector::empty();
        let i = start;
        while (i < end) {
            std::vector::push_back(&mut out, *std::vector::borrow(sb, i));
            i = i + 1;
        };
        string::utf8(out)
    }

    fun contains_substring(haystack: &vector<u8>, needle: vector<u8>): bool {
        let hlen = std::vector::length(haystack);
        let nlen = std::vector::length(&needle);
        if (nlen == 0 || nlen > hlen) return (nlen == 0);
        let i = 0;
        while (i <= hlen - nlen) {
            let matched = true;
            let j = 0;
            while (j < nlen) {
                if (*std::vector::borrow(haystack, i + j) != *std::vector::borrow(&needle, j)) {
                    matched = false;
                    break
                };
                j = j + 1;
            };
            if (matched) return true;
            i = i + 1;
        };
        false
    }

    /// Extract the hex string after "input":"0x" up to the closing quote.
    fun extract_input_hex(memo: &String): String {
        let bytes = *string::bytes(memo);
        let marker = b"\"input\":\"0x";
        let mlen = std::vector::length(&marker);
        let hlen = std::vector::length(&bytes);
        let start = 0;
        let found = false;
        let i = 0;
        while (i + mlen <= hlen) {
            let matched = true;
            let j = 0;
            while (j < mlen) {
                if (*std::vector::borrow(&bytes, i + j) != *std::vector::borrow(&marker, j)) {
                    matched = false;
                    break
                };
                j = j + 1;
            };
            if (matched) {
                start = i + mlen;
                found = true;
                break
            };
            i = i + 1;
        };
        assert!(found, 99);

        let out: vector<u8> = std::vector::empty();
        let k = start;
        while (k < hlen) {
            let c = *std::vector::borrow(&bytes, k);
            if (c == 0x22) break; // closing quote
            std::vector::push_back(&mut out, c);
            k = k + 1;
        };
        string::utf8(out)
    }
}
