// Copyright (c) 2024 Alibaba Group Holding Ltd.
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
	"github.com/higress-group/wasm-go/pkg/test"
	"github.com/stretchr/testify/require"
	"testing"
)

func TestInterruptedRequestKeepsRequestedModel(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		h := setupStreamingHost(t, []byte(`{"use_default_response_attributes":true}`))
		defer h.Reset()
		h.CompleteHttp()
		a := getAILogAttributes(t, h)
		require.Equal(t, "gpt-4", a["requested_model"])
		require.Equal(t, "gpt-4", a["model"])
		assertNoTokenAttrs(t, a)
	})
}
func TestInterruptedSplitEventKeepsMetadataWithoutUsage(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		h := setupStreamingHost(t, []byte(`{"use_default_response_attributes":true}`))
		defer h.Reset()
		e := sseEvent(`{"id":"upstream-123","model":"actual-model","choices":[{"delta":{"content":"secret output"}}]}`)
		deliverStreamChunk(t, h, e[:31], false)
		deliverStreamChunk(t, h, e[31:], false)
		h.CompleteHttp()
		a := getAILogAttributes(t, h)
		require.Equal(t, "upstream-123", a["chat_id"])
		require.Equal(t, "actual-model", a["model"])
		require.Equal(t, "gpt-4", a["requested_model"])
		require.Equal(t, "missing", a["usage_status"])
		assertNoTokenAttrs(t, a)
		require.NotContains(t, a, "answer")
		require.NotContains(t, a, "messages")
	})
}
func TestInterruptedPartialUsagePreservesOnlyReportedDimensions(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		h := setupStreamingHost(t, []byte(`{"use_default_response_attributes":true}`))
		defer h.Reset()
		deliverStreamChunk(t, h, sseEvent(`{"id":"partial","model":"gpt-4","usage":{"prompt_tokens":123,"prompt_tokens_details":{"cached_tokens":50}}}`), false)
		h.CompleteHttp()
		a := getAILogAttributes(t, h)
		require.Equal(t, float64(123), a["input_token"])
		_, known := aiLogInt64(a, "output_token")
		require.False(t, known, "unreported output must not become zero")
		require.Equal(t, "partial", a["usage_status"])
		n, e := h.GetCounterMetric(streamingMetricName("gpt-4", "input_token"))
		require.NoError(t, e)
		require.Equal(t, uint64(123), n)
	})
}
func TestUsageThenDoneDoesNotCountAsAbort(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		h := setupStreamingHost(t, []byte(`{"use_default_response_attributes":true}`))
		defer h.Reset()
		deliverStreamChunk(t, h, sseEvent(`{"model":"gpt-4","usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}`), false)
		deliverStreamChunk(t, h, sseEvent(`[DONE]`), false)
		h.CompleteHttp()
		a := getAILogAttributes(t, h)
		require.Equal(t, true, a["response_completed"])
		require.Equal(t, "complete", a["usage_status"])
		assertTokenMetrics(t, h, "gpt-4", 12, 3, 15)
		n, e := h.GetCounterMetric(streamingMetricName("gpt-4", LLMFailureCount))
		require.NoError(t, e)
		require.Zero(t, n)
	})
}
