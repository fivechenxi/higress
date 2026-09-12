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
	"bytes"
	"github.com/higress-group/wasm-go/pkg/tokenusage"
	"github.com/higress-group/wasm-go/pkg/wrapper"
	"github.com/tidwall/gjson"
	"math"
)

const requestedModel = "requested_model"
const responseCompleted = "response_completed"
const usageStatus = "usage_status"
const interruptedContext = "ai-statistics-interrupted"

// Capture only bounded metadata, never prompts or generated content. SSE callers
// pass a complete framed event so JSON fields split across callbacks survive.
func captureResponseMetadata(ctx wrapper.HttpContext, body []byte) {
	data := bytes.TrimSpace(wrapper.UnifySSEChunk(body))
	data = bytes.TrimSpace(bytes.TrimPrefix(data, []byte("data:")))
	if bytes.Equal(data, []byte("[DONE]")) {
		ctx.SetUserAttribute(responseCompleted, true)
	}
	if v := wrapper.GetValueFromBody(body, []string{"id", "response.id", "responseId", "message.id"}); v != nil && v.Type == gjson.String && v.String() != "" {
		ctx.SetUserAttribute(ChatID, v.String())
	}
	if v := wrapper.GetValueFromBody(body, []string{"model", "body.model", "response.model", "modelVersion", "message.model"}); v != nil && v.Type == gjson.String && v.String() != "" {
		ctx.SetUserAttribute(tokenusage.CtxKeyModel, v.String())
	}
	switch gjson.GetBytes(data, "type").String() {
	case "response.completed", "message_stop":
		ctx.SetUserAttribute(responseCompleted, true)
	}
	if m, ok := ctx.GetUserAttribute(tokenusage.CtxKeyModel).(string); !ok || m == "" {
		if m, ok := ctx.GetUserAttribute(requestedModel).(string); ok {
			ctx.SetUserAttribute(tokenusage.CtxKeyModel, m)
		}
	}
}

var inputScalarPaths = []string{tokenusage.UsageInputTokensPathOpenAIChatCompletions, tokenusage.UsageInputTokensPathOpenAIImages, tokenusage.UsageInputTokensPathOpenAIResponses, tokenusage.UsageInputTokensPathGemini, tokenusage.UsageInputTokensPathAnthropicMessages}
var outputScalarPaths = []string{tokenusage.UsageOutputTokensPathOpenAIChatCompletions, tokenusage.UsageOutputTokensPathOpenAIImages, tokenusage.UsageOutputTokensPathOpenAIResponses, tokenusage.UsageOutputTokensPathGemini, tokenusage.UsageOutputTokensPathAnthropicMessages}
var totalScalarPaths = []string{tokenusage.UsageTotalTokensPathOpenAIChatCompletions, tokenusage.UsageTotalTokensPathOpenAIResponses, tokenusage.UsageTotalTokensPathGemini}

func reportedScalar(body []byte, paths []string) (int64, bool) {
	v := wrapper.GetValueFromBody(body, paths)
	if v == nil || v.Type != gjson.Number {
		return 0, false
	}
	n := v.Float()
	if n < 0 || math.IsNaN(n) || math.IsInf(n, 0) || math.Trunc(n) != n || n >= float64(math.MaxInt64) {
		return 0, false
	}
	return int64(n), true
}
func restoreScalar(ctx wrapper.HttpContext, key string, previous interface{}, body []byte, paths []string) bool {
	if n, ok := reportedScalar(body, paths); ok {
		ctx.SetUserAttribute(key, n)
		return true
	}
	if previous == nil {
		delete(ctx.GetUserAttributeMap(), key)
	} else {
		ctx.SetUserAttribute(key, previous)
	}
	return false
}
func setUsageStatus(ctx wrapper.HttpContext) {
	in := ctx.GetUserAttribute(tokenusage.CtxKeyInputToken) != nil
	out := ctx.GetUserAttribute(tokenusage.CtxKeyOutputToken) != nil
	state := "missing"
	if in || out {
		state = "partial"
	}
	if in && out {
		state = "complete"
	}
	ctx.SetUserAttribute(usageStatus, state)
}
