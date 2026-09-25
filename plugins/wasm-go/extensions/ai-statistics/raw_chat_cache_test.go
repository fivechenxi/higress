package main

import (
	"testing"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/test"
	"github.com/stretchr/testify/require"
)

func TestRawChatCacheEvidence(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		for _, tc := range []struct {
			name, body         string
			flat, nested       interface{}
			flatRaw, nestedRaw string
		}{
			{"conflict", `{"usage":{"cached_tokens":9,"prompt_tokens_details":{"cached_tokens":7}}}`, float64(9), float64(7), "9", "7"},
			{"equal zero", `{"usage":{"cached_tokens":0,"prompt_tokens_details":{"cached_tokens":0}}}`, float64(0), float64(0), "0", "0"},
			{"flat only", `{"usage":{"cached_tokens":9}}`, float64(9), nil, "9", ""},
			{"invalid flat", `{"usage":{"cached_tokens":"sk-sensitive-identifier","prompt_tokens_details":{"cached_tokens":7}}}`, nil, float64(7), "invalid_type_or_oversized", "7"},
			{"null flat", `{"usage":{"cached_tokens":null}}`, nil, nil, "null", ""},
			{"boolean nested", `{"usage":{"prompt_tokens_details":{"cached_tokens":false}}}`, nil, nil, "", "false"},
			{"missing", `{"usage":{"prompt_tokens":5}}`, nil, nil, "", ""},
		} {
			for _, stream := range []bool{false, true} {
				for _, query := range []bool{false, true} {
					name := tc.name + map[bool]string{false: "/buffered", true: "/stream"}[stream]
					path := "/v1/chat/completions"
					if query {
						name += "/query"
						path += "?trace=1"
					}
					t.Run(name, func(t *testing.T) {
						var host test.TestHost
						if stream {
							host = setupStreamingHost(t, tokenDetailsConfig, path)
							deliverStreamChunks(t, host, sseEvent(tc.body))
						} else {
							var status types.OnPluginStartStatus
							host, status = test.NewTestHost(tokenDetailsConfig)
							require.Equal(t, types.OnPluginStartStatusOK, status)
							host.SetRouteName("api-v1")
							host.SetClusterName("cluster-1")
							host.CallOnHttpRequestHeaders([][2]string{{":authority", "example.com"}, {":path", path}, {":method", "POST"}})
							host.CallOnHttpRequestBody([]byte(`{"model":"gpt-4","messages":[]}`))
							host.CallOnHttpResponseHeaders([][2]string{{":status", "200"}, {"content-type", "application/json"}})
							host.CallOnHttpResponseBody([]byte(tc.body))
						}
						defer host.Reset()
						attrs := getAILogAttributes(t, host)
						require.Equal(t, tc.flat, attrs["cached_tokens_flat"])
						require.Equal(t, tc.nested, attrs["cached_tokens_nested"])
						require.Equal(t, tc.flatRaw, attrString(attrs, "cached_tokens_flat_raw"))
						require.Equal(t, tc.nestedRaw, attrString(attrs, "cached_tokens_nested_raw"))
						require.NotContains(t, attrString(attrs, "cached_tokens_flat_raw"), "sk-sensitive-identifier")
					})
				}
			}
		}
	})
}

func TestRawChatCacheSSEEventRetention(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		host := setupStreamingHost(t, tokenDetailsConfig, "/v1/chat/completions?trace=1")
		defer host.Reset()
		deliverStreamChunk(t, host, sseEvent(`{"usage":{"cached_tokens":9,"prompt_tokens_details":{"cached_tokens":7}}}`), false)
		attrs := getAILogAttributes(t, host)
		require.Equal(t, float64(9), attrs["cached_tokens_flat"])
		require.Equal(t, float64(7), attrs["cached_tokens_nested"])
		deliverStreamChunk(t, host, sseEvent(`{"usage":{"prompt_tokens":10,"completion_tokens":2}}`), false)
		attrs = getAILogAttributes(t, host)
		require.Equal(t, float64(9), attrs["cached_tokens_flat"])
		require.Equal(t, float64(7), attrs["cached_tokens_nested"])
		deliverStreamChunk(t, host, sseEvent(`{"usage":{"cached_tokens":4}}`), false)
		attrs = getAILogAttributes(t, host)
		require.Equal(t, float64(4), attrs["cached_tokens_flat"])
		require.NotContains(t, attrs, "cached_tokens_nested")
		require.Equal(t, "4", attrString(attrs, "cached_tokens_flat_raw"))
	})
}

func attrString(attrs map[string]interface{}, key string) string {
	value, _ := attrs[key].(string)
	return value
}
