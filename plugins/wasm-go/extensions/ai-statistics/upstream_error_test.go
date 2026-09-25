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
	"strings"
	"testing"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/test"
	"github.com/stretchr/testify/require"
)

func TestClassifyUpstreamError(t *testing.T) {
	tests := []struct {
		name      string
		status    string
		errorType string
		code      string
		message   string
		wantClass string
	}{
		{name: "context before generic invalid request", status: "400", errorType: "invalid_request_error", code: "context_length_exceeded", wantClass: ErrorClassContextLength},
		{name: "authentication status", status: "401", wantClass: ErrorClassAuthentication},
		{name: "permission status", status: "403", wantClass: ErrorClassPermission},
		{name: "rate limit status", status: "429", wantClass: ErrorClassRateLimit},
		{name: "quota exhausted takes precedence over 429", status: "429", code: "insufficient_quota", wantClass: ErrorClassQuotaExceeded},
		{name: "content policy in a 200 stream event", status: "200", errorType: "content_policy_violation", wantClass: ErrorClassContentPolicy},
		{name: "model unavailable", status: "400", message: "model not found", wantClass: ErrorClassModelUnavailable},
		{name: "provider timeout", status: "504", wantClass: ErrorClassTimeout},
		{name: "upstream internal", status: "503", wantClass: ErrorClassUpstreamInternal},
		{name: "other server error", status: "599", wantClass: ErrorClassOther5xx},
		{name: "other client error", status: "418", wantClass: ErrorClassOther4xx},
		{name: "provider error inside success transport", status: "200", errorType: "vendor_failure", wantClass: ErrorClassProviderError},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.wantClass, classifyUpstreamError(tt.status, tt.errorType, tt.code, tt.message, ""))
		})
	}
}

func TestExtractUpstreamErrorDetailsRedactsAndBounds(t *testing.T) {
	body := []byte(`{"error":{"type":"invalid_request_error","code":"invalid_parameter","message":"authorization Bearer secret-token-value"},"api_key":"tv_live_abcdefghijklmnopqrstuvwxyz","request_id":"provider-123"}`)
	details := extractUpstreamErrorDetails("400", body)
	require.Equal(t, ErrorClassInvalidRequest, details.Class)
	require.Equal(t, "invalid_request_error", details.Type)
	require.Equal(t, "invalid_parameter", details.Code)
	require.Equal(t, "provider-123", details.RequestID)
	require.NotContains(t, details.Message, "secret-token-value")
	require.NotContains(t, details.Body, "secret-token-value")
	require.NotContains(t, details.Body, "tv_live_abcdefghijklmnopqrstuvwxyz")
	require.Contains(t, details.Body, "[REDACTED]")
	require.False(t, details.BodyTruncated)

	longDetails := extractUpstreamErrorDetails("400", []byte(strings.Repeat("x", maxUpstreamErrorBodyBytes+100)))
	require.True(t, longDetails.BodyTruncated)
	require.Len(t, longDetails.Body, maxUpstreamErrorBodyBytes)
}

func TestUpstream400DiagnosticsAndMetric(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		host, status := test.NewTestHost(basicConfig)
		defer host.Reset()
		require.Equal(t, types.OnPluginStartStatusOK, status)
		host.SetRouteName("api-v1")
		host.SetClusterName("provider-a")

		host.CallOnHttpRequestHeaders([][2]string{
			{":authority", "example.com"},
			{":path", "/api/chat"},
			{":method", "POST"},
			{"x-mse-consumer", "user1"},
		})
		host.CallOnHttpRequestBody([]byte(`{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"test"}]}`))

		host.CallOnHttpResponseHeaders([][2]string{
			{":status", "400"},
			{"content-type", "text/plain"},
			{"x-tt-logid", "ark-log-id-123"},
		})
		host.CallOnHttpResponseBody([]byte(`{"code":"InvalidParameter","message":"invalid parameter: top_p"}`))
		host.CompleteHttp()

		aiLog := getAILogAttributes(t, host)
		require.Equal(t, ErrorClassInvalidRequest, aiLog[UpstreamErrorClass])
		require.Equal(t, "InvalidParameter", aiLog[UpstreamErrorCode])
		require.Equal(t, "invalid parameter: top_p", aiLog[UpstreamErrorMessage])
		require.Equal(t, "ark-log-id-123", aiLog["upstream_request_id"])
		require.Contains(t, aiLog[UpstreamErrorBody], "InvalidParameter")
		require.Equal(t, true, aiLog["response_error"])

		prefix := "route.api-v1.upstream.provider-a.model.deepseek-v4.1-flash.consumer.user1.metric."
		classified, err := host.GetCounterMetric(prefix + "llm_error_invalid_request_count")
		require.NoError(t, err)
		require.Equal(t, uint64(1), classified)
		failed, err := host.GetCounterMetric(prefix + LLMFailureCount)
		require.NoError(t, err)
		require.Equal(t, uint64(1), failed)
	})
}
