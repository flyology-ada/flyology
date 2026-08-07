#define _POSIX_C_SOURCE 200809L

/* OpenSSL 3 dynamic ABI adapter for Flyology.
 *
 * This file contains no cryptography.  It loads one matched libssl/libcrypto
 * installation and translates the stable OpenSSL 3 API to a small provider
 * ABI.  Module mappings follow the provider/session reference lifetime. */

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "flyology_tls_signal.h"

#define FLY_COMPLETE 0
#define FLY_WANT_READ -2
#define FLY_WANT_WRITE -3
#define FLY_PEER_CLOSED -4
#define FLY_FAILED -1

#define SSL_ERROR_NONE 0
#define SSL_ERROR_SSL 1
#define SSL_ERROR_WANT_READ 2
#define SSL_ERROR_WANT_WRITE 3
#define SSL_ERROR_SYSCALL 5
#define SSL_ERROR_ZERO_RETURN 6
#define SSL_VERIFY_NONE 0
#define SSL_VERIFY_PEER 1
#define SSL_FILETYPE_PEM 1
#define TLSEXT_NAMETYPE_host_name 0
#define SSL_CTRL_SET_TLSEXT_HOSTNAME 55
#define SSL_CTRL_MODE 33
#define SSL_CTRL_SET_MIN_PROTO_VERSION 123
#define SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER 0x00000002UL
#define SSL_TLSEXT_ERR_OK 0
#define SSL_TLSEXT_ERR_NOACK 3
#define TLS1_2_VERSION 0x0303
#define OPENSSL_VERSION 0

typedef struct ssl_ctx_st SSL_CTX;
typedef struct ssl_st SSL;
typedef struct ssl_method_st SSL_METHOD;
typedef struct x509_store_ctx_st X509_STORE_CTX;
typedef int (*SSL_verify_cb)(int, X509_STORE_CTX *);
typedef int (*SSL_alpn_select_cb)(SSL *, const unsigned char **,
                                  unsigned char *, const unsigned char *,
                                  unsigned int, void *);

struct fly_module {
   void *crypto;
   void *ssl;
   unsigned long (*OpenSSL_version_num)(void);
   const char *(*OpenSSL_version)(int);
   void (*ERR_clear_error)(void);
   unsigned long (*ERR_get_error)(void);
   void (*ERR_error_string_n)(unsigned long, char *, size_t);
   const SSL_METHOD *(*TLS_method)(void);
   SSL_CTX *(*SSL_CTX_new)(const SSL_METHOD *);
   void (*SSL_CTX_free)(SSL_CTX *);
   long (*SSL_CTX_ctrl)(SSL_CTX *, int, long, void *);
   void (*SSL_CTX_set_verify)(SSL_CTX *, int, SSL_verify_cb);
   int (*SSL_CTX_set_default_verify_paths)(SSL_CTX *);
   int (*SSL_CTX_load_verify_locations)(SSL_CTX *, const char *, const char *);
   int (*SSL_CTX_use_certificate_chain_file)(SSL_CTX *, const char *);
   int (*SSL_CTX_use_PrivateKey_file)(SSL_CTX *, const char *, int);
   int (*SSL_CTX_check_private_key)(const SSL_CTX *);
   void (*SSL_CTX_set_alpn_select_cb)(SSL_CTX *, SSL_alpn_select_cb, void *);
   SSL *(*SSL_new)(SSL_CTX *);
   void (*SSL_free)(SSL *);
   int (*SSL_set_fd)(SSL *, int);
   void (*SSL_set_connect_state)(SSL *);
   void (*SSL_set_accept_state)(SSL *);
   long (*SSL_ctrl)(SSL *, int, long, void *);
   int (*SSL_set1_host)(SSL *, const char *);
   int (*SSL_set_alpn_protos)(SSL *, const unsigned char *, unsigned int);
   void (*SSL_get0_alpn_selected)(const SSL *, const unsigned char **,
                                  unsigned int *);
   int (*SSL_do_handshake)(SSL *);
   int (*SSL_read)(SSL *, void *, int);
   int (*SSL_write)(SSL *, const void *, int);
   int (*SSL_get_error)(const SSL *, int);
   int (*SSL_shutdown)(SSL *);
};

struct fly_provider {
   struct fly_module *module;
   SSL_CTX *ctx;
   int side;
   unsigned char *alpn_protocols;
   unsigned int alpn_protocols_length;
   _Atomic unsigned refs;
};

struct fly_session {
   struct fly_provider *provider;
   SSL *ssl;
   int shutdown_complete;
   char error[1024];
};

static _Atomic unsigned live_modules;

static void set_error(char *buffer, size_t size, const char *message)
{
   if (buffer == NULL || size == 0) return;
   snprintf(buffer, size, "%s", message != NULL ? message : "unknown error");
}

static void append_dl_error(char *buffer, size_t size, const char *prefix)
{
   const char *detail = dlerror();
   if (buffer == NULL || size == 0) return;
   snprintf(buffer, size, "%s: %s", prefix,
            detail != NULL ? detail : "dynamic loader failure");
}

static int make_path(char *out, size_t size, const char *directory,
                     const char *name)
{
   int count;
   if (directory == NULL || directory[0] == '\0') {
      count = snprintf(out, size, "%s", name);
   } else {
      count = snprintf(out, size, "%s/%s", directory, name);
   }
   return count >= 0 && (size_t)count < size;
}

static void *required_symbol(void *handle, const char *name,
                             char *error, size_t error_size)
{
   void *symbol;
   dlerror();
   symbol = dlsym(handle, name);
   if (symbol == NULL) append_dl_error(error, error_size, name);
   return symbol;
}

#define LOAD(module, member, handle) do {                                      \
   void *fly_symbol = required_symbol((handle), #member, error, error_size);    \
   if (fly_symbol == NULL) goto fail;                                           \
   _Static_assert(sizeof((module)->member) == sizeof(fly_symbol),                \
                  "function and data pointers must have equal size");          \
   memcpy(&(module)->member, &fly_symbol, sizeof((module)->member));             \
} while (0)

static void destroy_module(struct fly_module *module)
{
   if (module == NULL) return;
   if (module->ssl != NULL) dlclose(module->ssl);
   if (module->crypto != NULL) dlclose(module->crypto);
   free(module);
   atomic_fetch_sub_explicit(&live_modules, 1, memory_order_relaxed);
}

#if FLYOLOGY_TLS_TEST_HOOKS
unsigned flyology_tls_openssl_live_modules(void)
{
   return atomic_load_explicit(&live_modules, memory_order_relaxed);
}
#endif

static struct fly_module *load_from_directory(const char *directory,
                                               char *error, size_t error_size)
{
   struct fly_module *module = NULL;
   void *dependency_version_symbol;
   void *explicit_version_symbol;
   unsigned long (*dependency_version)(void);
   unsigned long (*explicit_version)(void);
   char crypto_path[1024];
   char ssl_path[1024];
#if defined(__APPLE__)
   const char *crypto_name = "libcrypto.3.dylib";
   const char *ssl_name = "libssl.3.dylib";
#else
   const char *crypto_name = "libcrypto.so.3";
   const char *ssl_name = "libssl.so.3";
#endif

   if (!make_path(crypto_path, sizeof crypto_path, directory, crypto_name) ||
       !make_path(ssl_path, sizeof ssl_path, directory, ssl_name)) {
      set_error(error, error_size, "OpenSSL library directory is too long");
      return NULL;
   }

   module = calloc(1, sizeof *module);
   if (module == NULL) {
      set_error(error, error_size, "cannot allocate OpenSSL module table");
      return NULL;
   }
   atomic_fetch_add_explicit(&live_modules, 1, memory_order_relaxed);

   /* Load libssl first.  dlsym on that handle searches its dependency
    * closure, so this identifies the libcrypto image that libssl actually
    * bound to rather than merely checking two filenames. */
   module->ssl = dlopen(ssl_path, RTLD_NOW | RTLD_LOCAL);
   if (module->ssl == NULL) {
      append_dl_error(error, error_size, ssl_path);
      goto fail;
   }
   dependency_version_symbol = required_symbol
     (module->ssl, "OpenSSL_version_num", error, error_size);
   if (dependency_version_symbol == NULL) goto fail;

   module->crypto = dlopen(crypto_path, RTLD_NOW | RTLD_LOCAL);
   if (module->crypto == NULL) {
      append_dl_error(error, error_size, crypto_path);
      goto fail;
   }
   explicit_version_symbol = required_symbol
     (module->crypto, "OpenSSL_version_num", error, error_size);
   if (explicit_version_symbol == NULL) goto fail;
   _Static_assert(sizeof dependency_version == sizeof dependency_version_symbol,
                  "function and data pointers must have equal size");
   _Static_assert(sizeof explicit_version == sizeof explicit_version_symbol,
                  "function and data pointers must have equal size");
   memcpy(&dependency_version, &dependency_version_symbol,
          sizeof dependency_version);
   memcpy(&explicit_version, &explicit_version_symbol,
          sizeof explicit_version);
   if (dependency_version_symbol != explicit_version_symbol ||
       dependency_version() != explicit_version() ||
       (explicit_version() >> 28) != 3) {
      set_error(error, error_size,
                "libssl and libcrypto are not one matched OpenSSL 3.x pair");
      goto fail;
   }

   LOAD(module, OpenSSL_version_num, module->crypto);
   LOAD(module, OpenSSL_version, module->crypto);
   LOAD(module, ERR_clear_error, module->crypto);
   LOAD(module, ERR_get_error, module->crypto);
   LOAD(module, ERR_error_string_n, module->crypto);
   LOAD(module, TLS_method, module->ssl);
   LOAD(module, SSL_CTX_new, module->ssl);
   LOAD(module, SSL_CTX_free, module->ssl);
   LOAD(module, SSL_CTX_ctrl, module->ssl);
   LOAD(module, SSL_CTX_set_verify, module->ssl);
   LOAD(module, SSL_CTX_set_default_verify_paths, module->ssl);
   LOAD(module, SSL_CTX_load_verify_locations, module->ssl);
   LOAD(module, SSL_CTX_use_certificate_chain_file, module->ssl);
   LOAD(module, SSL_CTX_use_PrivateKey_file, module->ssl);
   LOAD(module, SSL_CTX_check_private_key, module->ssl);
   LOAD(module, SSL_CTX_set_alpn_select_cb, module->ssl);
   LOAD(module, SSL_new, module->ssl);
   LOAD(module, SSL_free, module->ssl);
   LOAD(module, SSL_set_fd, module->ssl);
   LOAD(module, SSL_set_connect_state, module->ssl);
   LOAD(module, SSL_set_accept_state, module->ssl);
   LOAD(module, SSL_ctrl, module->ssl);
   LOAD(module, SSL_set1_host, module->ssl);
   LOAD(module, SSL_set_alpn_protos, module->ssl);
   LOAD(module, SSL_get0_alpn_selected, module->ssl);
   LOAD(module, SSL_do_handshake, module->ssl);
   LOAD(module, SSL_read, module->ssl);
   LOAD(module, SSL_write, module->ssl);
   LOAD(module, SSL_get_error, module->ssl);
   LOAD(module, SSL_shutdown, module->ssl);

   return module;

fail:
   destroy_module(module);
   return NULL;
}

static struct fly_module *load_module(const char *directory,
                                      char *error, size_t error_size)
{
   struct fly_module *module;
   if (directory != NULL && directory[0] != '\0')
      return load_from_directory(directory, error, error_size);

#if defined(__APPLE__)
   static const char *directories[] = {
      "/opt/homebrew/opt/openssl@3/lib",
      "/usr/local/opt/openssl@3/lib",
      ""
   };
#else
   static const char *directories[] = { "" };
#endif
   for (size_t i = 0; i < sizeof directories / sizeof directories[0]; ++i) {
      module = load_from_directory(directories[i], error, error_size);
      if (module != NULL) return module;
   }
   return NULL;
}

static void provider_error(struct fly_module *module, char *buffer, size_t size,
                           const char *fallback)
{
   unsigned long code = module->ERR_get_error();
   if (code != 0) module->ERR_error_string_n(code, buffer, size);
   else set_error(buffer, size, fallback);
}

static int valid_alpn_list(const unsigned char *protocols, unsigned int length)
{
   unsigned int cursor = 0;
   if (length != 0 && protocols == NULL) return 0;
   while (cursor < length) {
      unsigned int item_length = protocols[cursor++];
      if (item_length == 0 || item_length > length - cursor) return 0;
      cursor += item_length;
   }
   return cursor == length;
}

static int select_alpn(SSL *ssl, const unsigned char **selected,
                       unsigned char *selected_length,
                       const unsigned char *offered,
                       unsigned int offered_length, void *argument)
{
   struct fly_provider *provider = argument;
   unsigned int server_cursor = 0;
   (void)ssl;
   if (!valid_alpn_list(offered, offered_length)) return SSL_TLSEXT_ERR_NOACK;
   while (server_cursor < provider->alpn_protocols_length) {
      unsigned int server_length = provider->alpn_protocols[server_cursor++];
      const unsigned char *server_value =
        provider->alpn_protocols + server_cursor;
      unsigned int client_cursor = 0;
      while (client_cursor < offered_length) {
         unsigned int client_length = offered[client_cursor++];
         const unsigned char *client_value = offered + client_cursor;
         if (client_length == server_length &&
             memcmp(client_value, server_value, server_length) == 0) {
            *selected = client_value;
            *selected_length = (unsigned char)client_length;
            return SSL_TLSEXT_ERR_OK;
         }
         client_cursor += client_length;
      }
      server_cursor += server_length;
   }
   return SSL_TLSEXT_ERR_NOACK;
}

void *flyology_tls_openssl_provider_create(int side, const char *ca_file,
                                            const char *certificate,
                                            const char *private_key,
                                            const char *directory,
                                            const unsigned char *protocols,
                                            unsigned int protocols_length,
                                            char *error, size_t error_size)
{
   struct fly_module *module = load_module(directory, error, error_size);
   struct fly_provider *provider;
   if (module == NULL) return NULL;

   provider = calloc(1, sizeof *provider);
   if (provider == NULL) {
      set_error(error, error_size, "cannot allocate OpenSSL provider");
      destroy_module(module);
      return NULL;
   }
   provider->module = module;
   provider->side = side;
   if (!valid_alpn_list(protocols, protocols_length)) {
      set_error(error, error_size, "invalid ALPN protocol list");
      free(provider);
      destroy_module(module);
      return NULL;
   }
   if (protocols_length != 0) {
      provider->alpn_protocols = malloc(protocols_length);
      if (provider->alpn_protocols == NULL) {
         set_error(error, error_size, "cannot allocate ALPN protocol list");
         free(provider);
         destroy_module(module);
         return NULL;
      }
      memcpy(provider->alpn_protocols, protocols, protocols_length);
      provider->alpn_protocols_length = protocols_length;
   }
   atomic_init(&provider->refs, 1);
   module->ERR_clear_error();
   provider->ctx = module->SSL_CTX_new(module->TLS_method());
   if (provider->ctx == NULL) {
      provider_error(module, error, error_size, "SSL_CTX_new failed");
      free(provider->alpn_protocols);
      free(provider);
      destroy_module(module);
      return NULL;
   }
   if (module->SSL_CTX_ctrl(provider->ctx, SSL_CTRL_SET_MIN_PROTO_VERSION,
                            TLS1_2_VERSION, NULL) != 1) {
      provider_error(module, error, error_size,
                     "cannot require TLS version 1.2 or newer");
      module->SSL_CTX_free(provider->ctx);
      free(provider->alpn_protocols);
      free(provider);
      destroy_module(module);
      return NULL;
   }

   if (side == 0) {
      module->SSL_CTX_set_verify(provider->ctx, SSL_VERIFY_PEER, NULL);
      if (ca_file != NULL && ca_file[0] != '\0') {
         if (module->SSL_CTX_load_verify_locations(provider->ctx, ca_file,
                                                    NULL) != 1) {
            provider_error(module, error, error_size,
                           "cannot load client trust file");
            module->SSL_CTX_free(provider->ctx);
            free(provider->alpn_protocols);
            free(provider);
            destroy_module(module);
            return NULL;
         }
      } else if (module->SSL_CTX_set_default_verify_paths(provider->ctx) != 1) {
         provider_error(module, error, error_size,
                        "cannot load default client trust paths");
         module->SSL_CTX_free(provider->ctx);
         free(provider->alpn_protocols);
         free(provider);
         destroy_module(module);
         return NULL;
      }
   } else {
      module->SSL_CTX_set_verify(provider->ctx, SSL_VERIFY_NONE, NULL);
      if (module->SSL_CTX_use_certificate_chain_file(provider->ctx,
                                                      certificate) != 1 ||
          module->SSL_CTX_use_PrivateKey_file(provider->ctx, private_key,
                                               SSL_FILETYPE_PEM) != 1 ||
          module->SSL_CTX_check_private_key(provider->ctx) != 1) {
         provider_error(module, error, error_size,
                        "cannot load matching server certificate and key");
         module->SSL_CTX_free(provider->ctx);
         free(provider->alpn_protocols);
         free(provider);
         destroy_module(module);
         return NULL;
      }
      if (provider->alpn_protocols_length != 0)
         module->SSL_CTX_set_alpn_select_cb(provider->ctx, select_alpn,
                                             provider);
   }
   return provider;
}

static void provider_release(struct fly_provider *provider)
{
   if (atomic_fetch_sub_explicit(&provider->refs, 1, memory_order_acq_rel) == 1) {
      struct fly_module *module = provider->module;
      module->SSL_CTX_free(provider->ctx);
      free(provider->alpn_protocols);
      free(provider);
      destroy_module(module);
   }
}

static int provider_retain(struct fly_provider *provider)
{
   unsigned refs = atomic_load_explicit(&provider->refs, memory_order_acquire);
   while (refs != 0) {
      if (atomic_compare_exchange_weak_explicit
          (&provider->refs, &refs, refs + 1,
           memory_order_acq_rel, memory_order_acquire))
         return 1;
   }
   return 0;
}

void *flyology_tls_openssl_provider_retain(void *handle)
{
   struct fly_provider *provider = handle;
   if (provider == NULL || !provider_retain(provider)) return NULL;
   return provider;
}

void flyology_tls_openssl_provider_release(void *handle)
{
   if (handle != NULL) provider_release(handle);
}

void flyology_tls_openssl_provider_version(void *handle, char *buffer,
                                           size_t size)
{
   struct fly_provider *provider = handle;
   if (provider == NULL || !provider_retain(provider)) {
      set_error(buffer, size, "");
      return;
   }
   set_error(buffer, size,
             provider->module->OpenSSL_version(OPENSSL_VERSION));
   provider_release(provider);
}

void *flyology_tls_openssl_session_create(void *provider_handle, int fd,
                                           int side, const char *server_name,
                                           const unsigned char *protocols,
                                           unsigned int protocols_length,
                                           char *error, size_t error_size)
{
   struct fly_provider *provider = provider_handle;
   struct fly_module *module;
   struct fly_session *session;
   if (provider == NULL || !provider_retain(provider)) {
      set_error(error, error_size, "provider is no longer available");
      return NULL;
   }
   if (provider->side != side) {
      set_error(error, error_size, "provider role does not match session");
      provider_release(provider);
      return NULL;
   }
   if (!valid_alpn_list(protocols, protocols_length) ||
       (side != 0 && protocols_length != 0)) {
      set_error(error, error_size, "invalid per-session ALPN protocol list");
      provider_release(provider);
      return NULL;
   }
   module = provider->module;
   session = calloc(1, sizeof *session);
   if (session == NULL) {
      set_error(error, error_size, "cannot allocate OpenSSL session");
      provider_release(provider);
      return NULL;
   }
   module->ERR_clear_error();
   session->ssl = module->SSL_new(provider->ctx);
   if (session->ssl == NULL || module->SSL_set_fd(session->ssl, fd) != 1) {
      provider_error(module, error, error_size, "cannot bind TLS descriptor");
      if (session->ssl != NULL) module->SSL_free(session->ssl);
      free(session);
      provider_release(provider);
      return NULL;
   }
   if (((unsigned long)module->SSL_ctrl
         (session->ssl, SSL_CTRL_MODE,
          (long)SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER, NULL)
       & SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER) == 0) {
      provider_error(module, error, error_size,
                     "cannot enable retry-safe TLS writes");
      module->SSL_free(session->ssl);
      free(session);
      provider_release(provider);
      return NULL;
   }
   if (side == 0) {
      if (server_name == NULL || server_name[0] == '\0' ||
          module->SSL_ctrl(session->ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME,
                           TLSEXT_NAMETYPE_host_name,
                           (void *)(uintptr_t)server_name) != 1 ||
          module->SSL_set1_host(session->ssl, server_name) != 1) {
         provider_error(module, error, error_size,
                        "cannot configure SNI and hostname verification");
         module->SSL_free(session->ssl);
         free(session);
         provider_release(provider);
         return NULL;
      }
      if (protocols_length != 0 &&
          module->SSL_set_alpn_protos(session->ssl, protocols,
                                      protocols_length) != 0) {
         provider_error(module, error, error_size,
                        "cannot configure ALPN protocol offer");
         module->SSL_free(session->ssl);
         free(session);
         provider_release(provider);
         return NULL;
      }
      module->SSL_set_connect_state(session->ssl);
   } else {
      module->SSL_set_accept_state(session->ssl);
   }
   session->provider = provider;
   return session;
}

void flyology_tls_openssl_session_free(void *handle)
{
   struct fly_session *session = handle;
   if (session == NULL) return;
   session->provider->module->SSL_free(session->ssl);
   provider_release(session->provider);
   free(session);
}

static int classify(struct fly_session *session, int result, int peer_close_ok)
{
   struct fly_module *module = session->provider->module;
   int error = module->SSL_get_error(session->ssl, result);
   if (error == SSL_ERROR_WANT_READ) return FLY_WANT_READ;
   if (error == SSL_ERROR_WANT_WRITE) return FLY_WANT_WRITE;
   if (error == SSL_ERROR_ZERO_RETURN && peer_close_ok) return FLY_PEER_CLOSED;
   provider_error(module, session->error, sizeof session->error,
                  error == SSL_ERROR_SYSCALL
                    ? "TLS transport ended without close_notify"
                    : "TLS protocol operation failed");
   return FLY_FAILED;
}

int flyology_tls_openssl_handshake(void *handle)
{
   struct fly_session *session = handle;
   struct fly_module *module = session->provider->module;
   struct flyology_sigpipe_guard guard;
   int result;
   int classified;
   if (flyology_sigpipe_begin(&guard) != 0) {
      set_error(session->error, sizeof session->error,
                "cannot establish scoped SIGPIPE guard");
      return FLY_FAILED;
   }
   module->ERR_clear_error();
   result = module->SSL_do_handshake(session->ssl);
   classified = result == 1 ? FLY_COMPLETE : classify(session, result, 0);
   flyology_sigpipe_end(&guard);
   return classified;
}

long flyology_tls_openssl_receive(void *handle, void *buffer, int count)
{
   struct fly_session *session = handle;
   struct fly_module *module = session->provider->module;
   struct flyology_sigpipe_guard guard;
   int result;
   long classified;
   if (flyology_sigpipe_begin(&guard) != 0) {
      set_error(session->error, sizeof session->error,
                "cannot establish scoped SIGPIPE guard");
      return FLY_FAILED;
   }
   module->ERR_clear_error();
   result = module->SSL_read(session->ssl, buffer, count);
   classified = result > 0 ? result : classify(session, result, 1);
   flyology_sigpipe_end(&guard);
   return classified;
}

long flyology_tls_openssl_send(void *handle, const void *buffer, int count)
{
   struct fly_session *session = handle;
   struct fly_module *module = session->provider->module;
   struct flyology_sigpipe_guard guard;
   int result;
   long classified;
   if (flyology_sigpipe_begin(&guard) != 0) {
      set_error(session->error, sizeof session->error,
                "cannot establish scoped SIGPIPE guard");
      return FLY_FAILED;
   }
   module->ERR_clear_error();
   result = module->SSL_write(session->ssl, buffer, count);
   classified = result > 0 ? result : classify(session, result, 0);
   flyology_sigpipe_end(&guard);
   return classified;
}

int flyology_tls_openssl_shutdown(void *handle)
{
   struct fly_session *session = handle;
   struct fly_module *module = session->provider->module;
   struct flyology_sigpipe_guard guard;
   int result;
   int classified;
   if (session->shutdown_complete) return FLY_COMPLETE;
   if (flyology_sigpipe_begin(&guard) != 0) {
      set_error(session->error, sizeof session->error,
                "cannot establish scoped SIGPIPE guard");
      return FLY_FAILED;
   }
   module->ERR_clear_error();
   result = module->SSL_shutdown(session->ssl);
   if (result == 1) {
      session->shutdown_complete = 1;
      classified = FLY_COMPLETE;
   } else if (result == 0) {
      classified = FLY_WANT_READ;
   } else {
      classified = classify(session, result, 0);
   }
   flyology_sigpipe_end(&guard);
   return classified;
}

void flyology_tls_openssl_session_error(void *handle, char *buffer, size_t size)
{
   struct fly_session *session = handle;
   set_error(buffer, size,
             session != NULL && session->error[0] != '\0'
               ? session->error : "TLS provider failed");
}

size_t flyology_tls_openssl_session_selected_protocol(void *handle,
                                                       unsigned char *buffer,
                                                       size_t size)
{
   struct fly_session *session = handle;
   const unsigned char *selected = NULL;
   unsigned int selected_length = 0;
   if (session == NULL) return 0;
   session->provider->module->SSL_get0_alpn_selected
     (session->ssl, &selected, &selected_length);
   if (selected == NULL || selected_length == 0) return 0;
   if (selected_length > size) return 0;
   memcpy(buffer, selected, selected_length);
   return selected_length;
}
