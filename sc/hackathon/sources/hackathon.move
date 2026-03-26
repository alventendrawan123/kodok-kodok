/// Local stub for the OneChain HACKATHON token.
///
/// Purpose: allows `sui move build` and `sui move test` to compile locally
/// without network access, while keeping ALL type references pointing to the
/// real deployed address:
///   0x8b76fc2a2317d45118770cefed7e57171a08c477ed16283616b15f099391f120
///
/// How it works: the [addresses] section in this package's Move.toml sets
/// `hackathon = "0x8b76..."` — so every use of `hackathon::hackathon::HACKATHON`
/// in the dependent packages compiles to the correct on-chain address.
/// The stub is NOT republished; the real on-chain package is used at runtime.
///
/// Decimal: 9  (1 HKT = 1_000_000_000 MIST)
module hackathon::hackathon;

/// One-time witness / phantom type for the HACKATHON game token.
/// Abilities mirror the real on-chain definition.
public struct HACKATHON has drop {}
