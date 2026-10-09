// Copyright (c) 2026 Alibaba Group Holding Ltd.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/higress-group/wasm-go/pkg/wrapper"
	"github.com/tidwall/gjson"
)

const (
	UpstreamErrorClass         = "upstream_error_class"
	UpstreamErrorType          = "upstream_error_type"
	UpstreamErrorCode          = "upstream_error_code"
	UpstreamErrorMessage       = "upstream_error_message"
	UpstreamErrorBody          = "upstream_error_body"
	UpstreamErrorBodyTruncated = "upstream_error_body_truncated"

	ErrorClassInvalidRequest   = "invalid_request"
	ErrorClassAuthentication   = "authentication"
	ErrorClassPermission       = "permission"
	ErrorClassNotFound         = "not_found"
	ErrorClassRateLimit        = "rate_limit"
	ErrorClassQuotaExceeded    = "quota_exceeded"
	ErrorClassContextLength    = "context_length"
	ErrorClassContentPolicy    = "content_policy"
	ErrorClassModelUnavailable = "model_unavailable"
	ErrorClassTimeout          = "timeout"
	ErrorClassUpstreamInternal = "upstream_internal"
	ErrorClassOther4xx         = "other_4xx"
	ErrorClassOther5xx         = "other_5xx"
	ErrorClassProviderError    = "provider_error"

	maxUpstreamErrorTypeBytes    = 128
	maxUpstreamErrorCodeBytes    = 128
	maxUpstreamErrorMessageBytes = 1024
	maxUpstreamErrorBodyBytes    = 4096
	maxUpstreamErrorParseBytes   = 64 * 1024
)

var upstreamErrorMetricByClass = map[string]string{
	ErrorClassInvalidRequest:   "llm_error_invalid_request_count",
	ErrorClassAuthentication:   "llm_error_authentication_count",
	ErrorClassPermission:       "llm_error_permission_count",
	ErrorClassNotFound:         "llm_error_not_found_count",
	ErrorClassRateLimit:        "llm_error_rate_limit_count",
	ErrorClassQuotaExceeded:    "llm_error_quota_exceeded_count",
	ErrorClassContextLength:    "llm_error_context_length_count",
	ErrorClassContentPolicy:    "llm_error_content_policy_count",
	ErrorClassModelUnavailable: "llm_error_model_unavailable_count",
	ErrorClassTimeout:          "llm_error_timeout_count",
	ErrorClassUpstreamInternal: "llm_error_upstream_internal_count",
	ErrorClassOther4xx:         "llm_error_other_4xx_count",
	ErrorClassOther5xx:         "llm_error_other_5xx_count",
	ErrorClassProviderError:    "llm_error_provider_error_count",
}

var (
	bearerSecretPattern = regexp.MustCompile(`(?i)(bearer\s+)[a-z0-9._~+/=-]{8,}`)
	tokenSecretPattern  = regexp.MustCompile(`(?i)\b(?:sk-|tv_(?:live|test|key)_)[a-z0-9_-]{8,}\b`)
	jsonSecretPattern   = regexp.MustCompile(`(?i)("(?:authorization|proxy_authorization|api[_-]?key|api[_-]?token|access[_-]?token|refresh[_-]?token|password|passwd|secret|client[_-]?secret|access[_-]?key|secret[_-]?key|credential|credentials)"\s*:\s*")[^"]*"`)
)

type upstreamErrorDetails struct {
	Class         string
	Type          string
	Code          string
	Message       string
	Body          string
	BodyTruncated bool
	RequestID     string
}

func captureUpstreamError(ctx wrapper.HttpContext, status string, body []byte) bool {
	if !isHTTPErrorStatus(status) && !hasErrorField(body) {
		return false
	}
	details := extractUpstreamErrorDetails(status, body)
	ctx.SetUserAttribute(UpstreamErrorClass, details.Class)
	if details.Type != "" {
		ctx.SetUserAttribute(UpstreamErrorType, details.Type)
	}
	if details.Code != "" {
		ctx.SetUserAttribute(UpstreamErrorCode, details.Code)
	}
	if details.Message != "" {
		ctx.SetUserAttribute(UpstreamErrorMessage, details.Message)
	}
	if details.Body != "" {
		ctx.SetUserAttribute(UpstreamErrorBody, details.Body)
		ctx.SetUserAttribute(UpstreamErrorBodyTruncated, details.BodyTruncated)
	}
	if current, _ := ctx.GetUserAttribute("upstream_request_id").(string); current == "" && details.RequestID != "" {
		ctx.SetUserAttribute("upstream_request_id", details.RequestID)
	}
	return true
}

func extractUpstreamErrorDetails(status string, body []byte) upstreamErrorDetails {
	diagnosticBody := body
	parseTruncated := len(diagnosticBody) > maxUpstreamErrorParseBytes
	if parseTruncated {
		diagnosticBody = diagnosticBody[:maxUpstreamErrorParseBytes]
	}
	details := upstreamErrorDetails{
		Type: firstScalar(diagnosticBody,
			"error.type", "error.error.type", "type"),
		Code: firstScalar(diagnosticBody,
			"error.code", "error.error.code", "code", "error_code", "errorCode", "base_resp.status_code"),
		Message: firstScalar(diagnosticBody,
			"error.message", "error.error.message", "message", "msg", "error_msg", "errorMessage", "base_resp.status_msg"),
		RequestID: firstScalar(diagnosticBody,
			"error.request_id", "error.requestId", "request_id", "requestId"),
	}
	details.Type, _ = truncateUTF8(redactSecrets(details.Type), maxUpstreamErrorTypeBytes)
	details.Code, _ = truncateUTF8(redactSecrets(details.Code), maxUpstreamErrorCodeBytes)
	details.Message, _ = truncateUTF8(redactSecrets(details.Message), maxUpstreamErrorMessageBytes)
	details.RequestID, _ = truncateUTF8(redactSecrets(details.RequestID), maxUpstreamErrorCodeBytes)
	details.Body, details.BodyTruncated = sanitizeUpstreamErrorBody(diagnosticBody)
	details.BodyTruncated = details.BodyTruncated || parseTruncated
	details.Class = classifyUpstreamError(status, details.Type, details.Code, details.Message, details.Body)
	return details
}

func firstScalar(body []byte, paths ...string) string {
	for _, path := range paths {
		value := gjson.GetBytes(body, path)
		if !value.Exists() || value.Value() == nil || value.IsObject() || value.IsArray() {
			continue
		}
		if text := value.String(); text != "" {
			return text
		}
	}
	return ""
}

func classifyUpstreamError(status, errorType, code, message, body string) string {
	text := strings.ToLower(strings.Join([]string{errorType, code, message, body}, " "))
	containsAny := func(values ...string) bool {
		for _, value := range values {
			if strings.Contains(text, value) {
				return true
			}
		}
		return false
	}

	// A provider may report exhausted commercial quota with HTTP 429. Prefer
	// its structured reason over the transport status so this does not look like
	// a transient RPM/TPM throttle.
	if containsAny("insufficient_quota", "quota_exceeded", "quota exceeded", "credit balance", "余额不足") {
		return ErrorClassQuotaExceeded
	}
	if status == "429" || containsAny("rate_limit", "rate limit", "too many request", "rpm limit", "tpm limit") {
		return ErrorClassRateLimit
	}
	if containsAny("context_length", "context length", "maximum context", "max_model_len", "too many tokens", "input too long", "token limit") {
		return ErrorClassContextLength
	}
	if containsAny("content_policy", "content filter", "content_filter", "moderation", "sensitive content", "risk control") {
		return ErrorClassContentPolicy
	}
	if containsAny("model_not_found", "model not found", "model unavailable", "model_unavailable", "no such model", "invalid model") {
		return ErrorClassModelUnavailable
	}
	if containsAny("authentication", "invalid_api_key", "invalid api key", "unauthorized", "signature mismatch", "invalid signature") {
		return ErrorClassAuthentication
	}
	if containsAny("permission", "forbidden", "access_denied", "access denied", "not authorized") {
		return ErrorClassPermission
	}
	if containsAny("timeout", "timed out", "deadline exceeded") {
		return ErrorClassTimeout
	}
	if containsAny("invalid_request", "invalid request", "invalid_parameter", "invalid parameter", "invalid_argument", "invalid argument", "bad request", "schema validation") {
		return ErrorClassInvalidRequest
	}

	statusCode, _ := strconv.Atoi(status)
	switch {
	case statusCode == 400 || statusCode == 409 || statusCode == 422:
		return ErrorClassInvalidRequest
	case statusCode == 401:
		return ErrorClassAuthentication
	case statusCode == 403:
		return ErrorClassPermission
	case statusCode == 404:
		return ErrorClassNotFound
	case statusCode == 408 || statusCode == 504:
		return ErrorClassTimeout
	case statusCode >= 400 && statusCode < 500:
		return ErrorClassOther4xx
	case statusCode >= 500 && statusCode < 600:
		if statusCode == 500 || statusCode == 502 || statusCode == 503 {
			return ErrorClassUpstreamInternal
		}
		return ErrorClassOther5xx
	default:
		return ErrorClassProviderError
	}
}

func isHTTPErrorStatus(status string) bool {
	code, err := strconv.Atoi(status)
	return err == nil && code >= 400
}

func sanitizeUpstreamErrorBody(body []byte) (string, bool) {
	if len(body) == 0 {
		return "", false
	}
	text := strings.ToValidUTF8(string(body), "?")
	var payload any
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	if decoder.Decode(&payload) == nil {
		redactSensitiveJSON(payload)
		if sanitized, err := json.Marshal(payload); err == nil {
			text = string(sanitized)
		}
	}
	text = redactSecrets(text)
	return truncateUTF8(text, maxUpstreamErrorBodyBytes)
}

func redactSensitiveJSON(value any) {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if isSensitiveErrorKey(key) {
				typed[key] = "[REDACTED]"
				continue
			}
			redactSensitiveJSON(child)
		}
	case []any:
		for _, child := range typed {
			redactSensitiveJSON(child)
		}
	}
}

func isSensitiveErrorKey(key string) bool {
	normalized := strings.NewReplacer("_", "", "-", "", ".", "").Replace(strings.ToLower(key))
	switch normalized {
	case "authorization", "proxyauthorization", "apikey", "apitoken", "accesstoken", "refreshtoken", "idtoken", "password", "passwd", "secret", "clientsecret", "accesskey", "secretkey", "credential", "credentials":
		return true
	default:
		return false
	}
}

func redactSecrets(value string) string {
	value = jsonSecretPattern.ReplaceAllString(value, "${1}[REDACTED]\"")
	value = bearerSecretPattern.ReplaceAllString(value, "${1}[REDACTED]")
	return tokenSecretPattern.ReplaceAllString(value, "[REDACTED]")
}

func truncateUTF8(value string, limit int) (string, bool) {
	if len(value) <= limit {
		return value, false
	}
	value = value[:limit]
	for !utf8.ValidString(value) {
		value = value[:len(value)-1]
	}
	return value, true
}

func upstreamErrorMetricName(class string) (string, bool) {
	metric, ok := upstreamErrorMetricByClass[class]
	return metric, ok
}
