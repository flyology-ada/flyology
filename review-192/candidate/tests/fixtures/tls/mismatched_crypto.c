/* Deliberately not OpenSSL.  The TLS smoke runner installs this test-only
 * library beside a real libssl to verify that the adapter rejects a pair whose
 * libssl dependency is not the explicitly selected libcrypto image. */
unsigned long OpenSSL_version_num(void)
{
   return 0x30000000UL;
}
