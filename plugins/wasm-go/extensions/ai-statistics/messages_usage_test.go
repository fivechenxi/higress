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
	"fmt"
	"testing"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/test"
	"github.com/stretchr/testify/require"
)

func TestMessagesCacheReadUsageInLog(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		for _, tc := range []struct {
			name, cache string
			known       bool
			want        float64
		}{
			{"zero", `,"cache_read_input_tokens":0`, true, 0},
			{"hit", `,"cache_read_input_tokens":5`, true, 5},
			{"absent", "", false, 0},
			{"null", `,"cache_read_input_tokens":null`, false, 0},
			{"negative", `,"cache_read_input_tokens":-1`, false, 0},
			{"fractional", `,"cache_read_input_tokens":0.5`, false, 0},
			{"string", `,"cache_read_input_tokens":"0"`, false, 0},
			{"creation_only", `,"cache_creation_input_tokens":5`, false, 0},
		} {
			for _, streaming := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/stream=%v", tc.name, streaming), func(t *testing.T) {
					host, status := test.NewTestHost(json.RawMessage(`{"enable_path_suffixes":["/v1/messages"],"use_default_response_attributes":true}`))
					require.Equal(t, types.OnPluginStartStatusOK, status)
					defer host.Reset()
					host.SetRouteName("api-v1")
					host.SetClusterName("cluster-1")
					host.CallOnHttpRequestHeaders([][2]string{{":authority", "example.com"}, {":method", "POST"}, {":path", "/v1/messages"}, {"x-mse-consumer", "user1"}})
					host.CallOnHttpRequestBody([]byte(fmt.Sprintf(`{"model":"test","stream":%v,"messages":[]}`, streaming)))
					contentType := "application/json"
					if streaming {
						contentType = "text/event-stream"
					}
					host.CallOnHttpResponseHeaders([][2]string{{":status", "200"}, {"content-type", contentType}})
					usage := fmt.Sprintf(`{"input_tokens":15,"output_tokens":16%s}`, tc.cache)
					if streaming {
						deliverStreamChunk(t, host, sseEvent(`{"type":"message_delta","usage":`+usage+`}`), true)
					} else {
						host.CallOnHttpResponseBody([]byte(`{"id":"usage-test","model":"test","type":"message","usage":` + usage + `}`))
					}
					host.CompleteHttp()
					attrs := getAILogAttributes(t, host)
					value := attrs["cached_tokens"]
					if tc.known {
						require.Equal(t, tc.want, value)
					} else {
						require.Nil(t, value)
					}
				})
			}
		}
	})
}

func TestMessagesStartCacheUsageSurvivesFinalDelta(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		host := setupStreamingHost(t, json.RawMessage(`{"enable_path_suffixes":["/v1/chat/completions"],"use_default_response_attributes":true}`))
		defer host.Reset()
		deliverStreamChunk(t, host, sseEvent(`{"type":"message_start","message":{"id":"start-test","model":"test","usage":{"input_tokens":15,"output_tokens":0,"cache_read_input_tokens":5,"cache_creation_input_tokens":0}}}`), false)
		deliverStreamChunk(t, host, sseEvent(`{"type":"message_delta","usage":{"output_tokens":8,"cache_read_input_tokens":null}}`), false)
		deliverStreamChunk(t, host, sseEvent(`{"type":"message_delta","usage":{"output_tokens":16}}`), true)
		attrs := getAILogAttributes(t, host)
		require.Equal(t, float64(5), attrs["cached_tokens"])
		assertTokenAttrs(t, attrs, 15, 16, 36)
		host.CompleteHttp()
	})
}
