// CEF bridge implementation for cmux.
//
// This file wraps CEF C++ API calls behind the plain C interface declared
// in cef_bridge.h. CEF headers are included conditionally; when building
// without CEF (e.g. stub mode for CI or WebKit-only builds), every
// function returns an appropriate no-op/error value.
//
// The actual CEF integration will be filled in during Phase 2 once the
// framework download and helper process infrastructure is in place.

#include "cef_bridge.h"

#include <cstdlib>
#include <cstring>

// TODO(phase2): #include "include/cef_app.h" etc. once CEF is available

// -------------------------------------------------------------------
// Internal state
// -------------------------------------------------------------------

static bool g_initialized = false;

// -------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr;
    size_t len = strlen(s) + 1;
    char* copy = static_cast<char*>(malloc(len));
    if (copy) memcpy(copy, s, len);
    return copy;
}

// -------------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------------

bool cef_bridge_framework_available(const char* framework_path) {
    if (!framework_path) return false;
    // TODO(phase2): check for Chromium Embedded Framework.framework at path
    // For now, return false (framework not present)
    return false;
}

int cef_bridge_initialize(
    const char* framework_path,
    const char* helper_path,
    const char* cache_root
) {
    if (g_initialized) return CEF_BRIDGE_OK;
    if (!framework_path || !helper_path || !cache_root) {
        return CEF_BRIDGE_ERR_INVALID;
    }

    // TODO(phase2): CefInitialize with CefSettings
    // - external_message_pump = true
    // - framework_dir_path = framework_path
    // - browser_subprocess_path = helper_path
    // - cache_path = cache_root
    // - no_sandbox = true

    // Stub: return not-initialized until CEF is wired up
    return CEF_BRIDGE_ERR_NOT_INIT;
}

void cef_bridge_do_message_loop_work(void) {
    if (!g_initialized) return;
    // TODO(phase2): CefDoMessageLoopWork()
}

void cef_bridge_shutdown(void) {
    if (!g_initialized) return;
    // TODO(phase2): CefShutdown()
    g_initialized = false;
}

bool cef_bridge_is_initialized(void) {
    return g_initialized;
}

// -------------------------------------------------------------------
// Profile management
// -------------------------------------------------------------------

cef_bridge_profile_t cef_bridge_profile_create(const char* cache_path) {
    if (!g_initialized || !cache_path) return nullptr;
    // TODO(phase2): CefRequestContext::CreateContext with cache_path
    return nullptr;
}

void cef_bridge_profile_destroy(cef_bridge_profile_t profile) {
    if (!profile) return;
    // TODO(phase2): release CefRequestContext ref
}

int cef_bridge_profile_clear_data(cef_bridge_profile_t profile) {
    if (!g_initialized || !profile) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefRequestContext::ClearCertificateExceptions etc.
    return CEF_BRIDGE_ERR_NOT_INIT;
}

// -------------------------------------------------------------------
// Browser view
// -------------------------------------------------------------------

cef_bridge_browser_t cef_bridge_browser_create(
    cef_bridge_profile_t profile,
    const char* initial_url,
    const cef_bridge_client_callbacks* callbacks
) {
    if (!g_initialized) return nullptr;
    // TODO(phase2): CefBrowserView::CreateBrowserView
    return nullptr;
}

void cef_bridge_browser_destroy(cef_bridge_browser_t browser) {
    if (!browser) return;
    // TODO(phase2): CefBrowserHost::CloseBrowser(true)
}

void* cef_bridge_browser_get_nsview(cef_bridge_browser_t browser) {
    if (!browser) return nullptr;
    // TODO(phase2): return CefBrowserView::GetNSView()
    return nullptr;
}

// -------------------------------------------------------------------
// Navigation
// -------------------------------------------------------------------

int cef_bridge_browser_load_url(cef_bridge_browser_t browser, const char* url) {
    if (!g_initialized || !browser || !url) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefBrowser::GetMainFrame()->LoadURL
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_go_back(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_go_forward(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_reload(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_stop(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    return CEF_BRIDGE_ERR_NOT_INIT;
}

char* cef_bridge_browser_get_url(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return nullptr;
    return nullptr;
}

char* cef_bridge_browser_get_title(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return nullptr;
    return nullptr;
}

bool cef_bridge_browser_can_go_back(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return false;
    return false;
}

bool cef_bridge_browser_can_go_forward(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return false;
    return false;
}

bool cef_bridge_browser_is_loading(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return false;
    return false;
}

// -------------------------------------------------------------------
// Page control
// -------------------------------------------------------------------

int cef_bridge_browser_set_zoom(cef_bridge_browser_t browser, double level) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    return CEF_BRIDGE_ERR_NOT_INIT;
}

double cef_bridge_browser_get_zoom(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return 0.0;
    return 0.0;
}

int cef_bridge_browser_set_user_agent(
    cef_bridge_browser_t browser,
    const char* user_agent
) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    return CEF_BRIDGE_ERR_NOT_INIT;
}

// -------------------------------------------------------------------
// JavaScript
// -------------------------------------------------------------------

int cef_bridge_browser_execute_js(
    cef_bridge_browser_t browser,
    const char* script
) {
    if (!g_initialized || !browser || !script) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefBrowser::GetMainFrame()->ExecuteJavaScript
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_evaluate_js(
    cef_bridge_browser_t browser,
    const char* script,
    int32_t request_id,
    cef_bridge_js_callback callback,
    void* user_data
) {
    if (!g_initialized || !browser || !script || !callback) {
        return CEF_BRIDGE_ERR_NOT_INIT;
    }
    // TODO(phase2): send CefProcessMessage to renderer, renderer evals
    // and replies, browser process dispatches callback
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_add_init_script(
    cef_bridge_browser_t browser,
    const char* script
) {
    if (!g_initialized || !browser || !script) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): track script, inject in OnContextCreated
    return CEF_BRIDGE_ERR_NOT_INIT;
}

// -------------------------------------------------------------------
// DevTools
// -------------------------------------------------------------------

int cef_bridge_browser_show_devtools(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefBrowserHost::ShowDevTools
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_close_devtools(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefBrowserHost::CloseDevTools
    return CEF_BRIDGE_ERR_NOT_INIT;
}

// -------------------------------------------------------------------
// Visibility (portal support)
// -------------------------------------------------------------------

void cef_bridge_browser_set_hidden(cef_bridge_browser_t browser, bool hidden) {
    if (!g_initialized || !browser) return;
    // TODO(phase2): CefBrowserHost::WasHidden(hidden)
}

void cef_bridge_browser_notify_resized(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return;
    // TODO(phase2): CefBrowserHost::WasResized()
}

// -------------------------------------------------------------------
// Find in page
// -------------------------------------------------------------------

int cef_bridge_browser_find(
    cef_bridge_browser_t browser,
    const char* search_text,
    bool forward,
    bool case_sensitive
) {
    if (!g_initialized || !browser || !search_text) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefBrowserHost::Find
    return CEF_BRIDGE_ERR_NOT_INIT;
}

int cef_bridge_browser_stop_finding(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    // TODO(phase2): CefBrowserHost::StopFinding
    return CEF_BRIDGE_ERR_NOT_INIT;
}

// -------------------------------------------------------------------
// Extensions
// -------------------------------------------------------------------

cef_bridge_extension_t cef_bridge_extension_load(
    cef_bridge_profile_t profile,
    const char* extension_path
) {
    if (!g_initialized || !profile || !extension_path) return nullptr;
    // TODO(phase4): CefRequestContext::LoadExtension
    return nullptr;
}

int cef_bridge_extension_unload(cef_bridge_extension_t extension) {
    if (!extension) return CEF_BRIDGE_ERR_INVALID;
    // TODO(phase4): CefExtension::Unload
    return CEF_BRIDGE_ERR_NOT_INIT;
}

char* cef_bridge_extension_get_id(cef_bridge_extension_t extension) {
    if (!extension) return nullptr;
    // TODO(phase4): CefExtension::GetIdentifier
    return nullptr;
}

// -------------------------------------------------------------------
// Utility
// -------------------------------------------------------------------

void cef_bridge_free_string(char* str) {
    free(str);
}

char* cef_bridge_get_version(void) {
    // TODO(phase2): return actual CEF version from cef_version_info
    return bridge_strdup("0.0.0-stub");
}
