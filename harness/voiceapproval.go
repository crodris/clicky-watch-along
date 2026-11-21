package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"unicode"
)

// A voice answer to an approval request is decided here, next to the approval gate that holds the request. The model
// reads only the capability word of a waiting request, and it can be talked into a yes by text a page wrote, such as a
// video title, so a yes counts only when the learner's own transcript is a short answer. This file is the port of
// leanring-buddy/VoiceApprovals.swift (`approvalVoiceAnswerTheLearnerSaid` and the `ApprovalVoiceAnswer` vocabulary).
// testdata/approval-voice-answers.json is read by a test on each side, so the two cannot differ while both exist.

// answerApprovalTool is the brain's tool for answering the request a background agent waits on. The app lists it only
// while a request waits, and the brain offers it only when the gate agrees (see offersForACommand).
const answerApprovalTool toolName = "answer_approval"

// approvalVoiceAnswer is the model's answer to a waiting request, read from the tool's input.
type approvalVoiceAnswer struct {
	approved bool
	scope    string
}

// approvalVoiceAnswerFromToolInput reads the tool's input at the boundary. It is false when `approved` is missing or
// not a boolean, so a malformed call never answers by guessing. "Always" only means something with a yes, since a no is
// never remembered, so a no with always set stays a plain no.
func approvalVoiceAnswerFromToolInput(input map[string]any) (approvalVoiceAnswer, bool) {
	approved, approvedIsBoolean := input["approved"].(bool)
	if !approvedIsBoolean {
		return approvalVoiceAnswer{}, false
	}
	always, _ := input["always"].(bool)
	if approved && always {
		return approvalVoiceAnswer{approved: true, scope: approvalScopeAlways}, true
	}
	return approvalVoiceAnswer{approved: approved, scope: approvalScopeOnce}, true
}

// Words that say yes, and phrases of two words that do.
var approvalYesWords = wordSet("yes", "yeah", "yep", "yup", "sure", "ok", "okay", "allow", "approve", "approved", "fine", "alright")

var approvalYesPhrases = []string{"go ahead", "do it", "all right"}

// Words that say no. "not" covers "do not" and "don't allow".
var approvalNoWords = wordSet("no", "nope", "nah", "not", "don't", "dont", "stop", "cancel", "decline", "deny", "never")

// The other words a short yes may hold, such as "yes please", "go ahead and do it", or "always allow that, thanks".
var approvalAnswerFillerWords = wordSet(
	"go", "ahead", "do", "it", "that", "this", "one", "please", "always", "all", "right", "and", "thanks", "thank", "you", "hey", "clicky", "of", "course",
)

func wordSet(words ...string) map[string]bool {
	set := make(map[string]bool, len(words))
	for _, word := range words {
		set[word] = true
	}
	return set
}

// approvalTranscriptWords splits a transcript the way the Swift check does: lowercase, a curly apostrophe as a straight
// one, and a word is a run of letters and apostrophes. A combining mark counts as part of its word, as a Swift Character
// holds it, so a mark never turns a word outside the vocabulary into one inside it.
func approvalTranscriptWords(transcript string) []string {
	lowered := strings.ReplaceAll(strings.ToLower(transcript), "’", "'")
	return strings.FieldsFunc(lowered, func(character rune) bool {
		return !unicode.IsLetter(character) && !unicode.IsMark(character) && character != '\''
	})
}

// approvalVoiceAnswerTheLearnerSaid is the model's answer when the learner's own words support it, or false when they do
// not. A yes counts only when the whole transcript is a short answer: it says yes, holds no word of no, and has no word
// outside the answer's vocabulary, so "okay, what is this video about" is not a yes. An "always" counts only when the
// learner said always. A no needs no check, since declining is always safe. The answer is refused rather than changed,
// so the chip, which reads the answer the harness settles, never names one the learner did not give.
func approvalVoiceAnswerTheLearnerSaid(modelAnswer approvalVoiceAnswer, transcript string) (approvalVoiceAnswer, bool) {
	if !modelAnswer.approved {
		return modelAnswer, true
	}
	transcriptWords := approvalTranscriptWords(transcript)
	spacedTranscript := " " + strings.Join(transcriptWords, " ") + " "
	saysNo := false
	saysYes := false
	saysAlways := false
	isAShortAnswer := true
	for _, word := range transcriptWords {
		saysNo = saysNo || approvalNoWords[word]
		saysYes = saysYes || approvalYesWords[word]
		saysAlways = saysAlways || word == "always"
		isAShortAnswer = isAShortAnswer && (approvalYesWords[word] || approvalAnswerFillerWords[word])
	}
	for _, phrase := range approvalYesPhrases {
		saysYes = saysYes || strings.Contains(spacedTranscript, " "+phrase+" ")
	}
	// A bare "always" is a yes too, when the model heard it as one.
	saysYes = saysYes || (modelAnswer.scope == approvalScopeAlways && saysAlways)
	if !saysYes || saysNo || !isAShortAnswer {
		return approvalVoiceAnswer{}, false
	}
	if modelAnswer.scope == approvalScopeAlways && !saysAlways {
		return approvalVoiceAnswer{}, false
	}
	return modelAnswer, true
}

// approvalOffer is what a command may do about approvals, decided when it begins from the request the app says the
// learner had seen at the press and the gate's own record of it. The zero value means no request can be answered.
type approvalOffer struct {
	approvalID string
	// capabilityWord is the kind of action the request asks for ("sends", "deletes", "spends", or "reads_private"), the
	// only thing about it the model reads. The summary can hold text a web page or an MCP server wrote, so it never
	// reaches the model.
	capabilityWord string
}

// answerableApproval is the request a voice yes or no may answer: the one the learner had seen at the press, and only
// while the gate still holds it as waiting. A request that was answered, abandoned, or never existed is not answerable.
func (gate *approvalGate) answerableApproval(approvalIDSeenAtPress *string) approvalOffer {
	if approvalIDSeenAtPress == nil {
		return approvalOffer{}
	}
	needed, isWaiting := gate.waitingCapability(*approvalIDSeenAtPress)
	if !isWaiting {
		return approvalOffer{}
	}
	return approvalOffer{approvalID: *approvalIDSeenAtPress, capabilityWord: string(needed)}
}

// canBeAnswered says whether a command may offer and run answer_approval.
func (offer approvalOffer) canBeAnswered() bool {
	return offer.approvalID != ""
}

// offersForACommand is the app's tool list with answer_approval left out unless the gate holds the request the learner
// had seen. This is the offer rule: the app lists the tool while its own desk shows a request, and the harness lists it
// only while its gate agrees, so a request that was answered by a click in the meantime is never offered.
func offersForACommand(appOffers []voiceToolOffer, offer approvalOffer) []voiceToolOffer {
	if offer.canBeAnswered() {
		return appOffers
	}
	kept := make([]voiceToolOffer, 0, len(appOffers))
	for _, appOffer := range appOffers {
		if toolName(appOffer.Name) != answerApprovalTool {
			kept = append(kept, appOffer)
		}
	}
	return kept
}

// approvalWaitingKey is the scene state field that names the kind of action a waiting request asks for.
const approvalWaitingKey = "approvalWaiting"

// sceneStateForACommand is the scene state the model reads: the app's own, with the harness's word for the waiting
// request. The app sends no approvalWaiting, and one it did send is dropped, since only the gate knows whether a request
// waits. The app's bytes are kept when nothing changes, and the members keep their order when something does.
func sceneStateForACommand(appSceneState json.RawMessage, offer approvalOffer) json.RawMessage {
	members, parseErr := orderedObjectMembers(appSceneState)
	if parseErr != nil {
		// Not an object, so the app's text stays as it is unless the request needs a field of its own.
		members = nil
	}
	hasAnApprovalField := slices.ContainsFunc(members, func(member objectMember) bool { return member.key == approvalWaitingKey })
	if !hasAnApprovalField && !offer.canBeAnswered() {
		return appSceneState
	}
	var rebuilt bytes.Buffer
	rebuilt.WriteByte('{')
	wroteAMember := false
	for _, member := range members {
		if member.key == approvalWaitingKey {
			continue
		}
		if wroteAMember {
			rebuilt.WriteByte(',')
		}
		rebuilt.Write(mustMarshal(member.key))
		rebuilt.WriteByte(':')
		rebuilt.Write(member.value)
		wroteAMember = true
	}
	if offer.canBeAnswered() {
		if wroteAMember {
			rebuilt.WriteByte(',')
		}
		rebuilt.Write(mustMarshal(approvalWaitingKey))
		rebuilt.WriteByte(':')
		rebuilt.Write(mustMarshal(offer.capabilityWord))
	}
	rebuilt.WriteByte('}')
	return rebuilt.Bytes()
}

// answerTheApproval runs the model's answer_approval call without asking the app, since only the harness knows whether the
// request still waits and the answer goes to the gate. It returns the call's outcome and the result text the model reads.
// It answers only in the command's first reply, since a later turn has read tool results, which can hold text a page or a
// server wrote. It then needs the learner's own words to support the answer (approvalVoiceAnswerTheLearnerSaid), and the
// gate to take it before any click did. A settled request is announced to the app with approval_settled, even when the
// command was cancelled meanwhile, since the gate already took the answer and the app's card must go.
func (brain *brainRunner) answerTheApproval(call toolCall, offer approvalOffer, turnIndex int, transcript string) (voiceToolOutcome, string) {
	if turnIndex != 0 {
		return voiceToolFailed, voiceToolFailureText("answer_approval answers only in the first reply to the learner's words")
	}
	if !offer.canBeAnswered() {
		return voiceToolFailed, voiceToolFailureText("no request waits for an answer")
	}
	input, _ := decodedToolInput(call.Input)
	modelAnswer, inputIsValid := approvalVoiceAnswerFromToolInput(input)
	if !inputIsValid {
		return voiceToolFailed, voiceToolFailureText("answer_approval needs approved set to true or false")
	}
	learnerAnswer, learnerSaidIt := approvalVoiceAnswerTheLearnerSaid(modelAnswer, transcript)
	if !learnerSaidIt {
		return voiceToolFailed, voiceToolFailureText("the learner's words are not a short answer to the request, so it stays waiting")
	}
	if !brain.approvals.deliver(approvalResultMessage{ApprovalID: offer.approvalID, Approved: learnerAnswer.approved, Scope: learnerAnswer.scope}) {
		return voiceToolFailed, voiceToolFailureText("the request was already answered")
	}
	brain.writer.send(newApprovalSettledMessage(offer.approvalID, learnerAnswer.approved, learnerAnswer.scope))
	verdict := "declined"
	if learnerAnswer.approved {
		verdict = "given"
	}
	brain.writer.send(newLogMessage(fmt.Sprintf("Brain: approval %s %s (%s)", offer.approvalID, verdict, learnerAnswer.scope)))
	answerWord := "declined"
	if learnerAnswer.approved {
		answerWord = "allowed"
	}
	return voiceToolChanged, string(mustMarshal(map[string]any{"ok": true, "state": map[string]any{"approval": answerWord}}))
}
