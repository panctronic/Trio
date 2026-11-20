#! /bin/sh
#
# Runs SwiftFormat (built from BuildTools/) with Trio's rule set.
#
# Usage: scripts/swiftformat.sh [--lint] [path ...]
#
#   Format (default): rewrites files in place. With no paths it formats the
#   whole of ${SRCROOT}; this is what the "Swiftformat" build phase of the Trio
#   target runs on every build (it `source`s this file with SRCROOT set).
#   Pass paths to format only those files, e.g. the ones you changed:
#       scripts/swiftformat.sh $(git diff --name-only -- '*.swift')
#   Skipped when CI=true so CI builds never modify the checkout.
#
#   Lint (--lint): only reports code that is not formatted and exits non-zero
#   if there is any; nothing is modified. Runs regardless of CI (CI uses it).
#   With no paths it checks the whole of ${SRCROOT}.
#
# SRCROOT defaults to the repository root when the script is run by hand.
# Run it from the repository root: the --exclude paths below are relative to
# the current directory.

SWIFTFORMAT_MODE=format
if [ "$1" = "--lint" ]; then
	SWIFTFORMAT_MODE=lint
	shift
fi

if [ "$SWIFTFORMAT_MODE" = "format" ] && [ "$CI" = "true" ]; then
	echo "CI detected - skipping SwiftFormat (CI runs scripts/swiftformat.sh --lint instead)."
	exit 0
fi

if [ -z "${SRCROOT}" ] && [ "$(basename "$0")" = "swiftformat.sh" ]; then
	SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

function assertEnvironment {
	if [ -z $1 ]; then 
		echo $2
		exit 127
	fi
}

assertEnvironment "${SRCROOT}" "Please set SRCROOT to project root folder"

unset SDKROOT

if [ $# -eq 0 ]; then
	set -- "${SRCROOT}"
fi
if [ "$SWIFTFORMAT_MODE" = "lint" ]; then
	# --lint: report unformatted code and fail, never write.
	set -- --lint "$@"
fi

swift run -c release --package-path "${SRCROOT}/BuildTools" swiftformat "$@" \
--enable andOperator,\
anyObjectProtocol,\
blankLinesAroundMark,\
blankLinesAtEndOfScope,\
blankLinesAtStartOfScope,\
blankLinesBetweenScopes,\
consecutiveBlankLines,\
consecutiveSpaces,\
duplicateImports,\
elseOnSameLine,\
emptyBraces,\
enumNamespaces,\
fileHeader,\
hoistPatternLet,\
indent,\
isEmpty,\
leadingDelimiters,\
linebreakAtEndOfFile,\
linebreaks,\
modifierOrder,\
numberFormatting,\
preferKeyPath,\
redundantBackticks,\
redundantBreak,\
redundantExtensionACL,\
redundantFileprivate,\
redundantGet,\
redundantLet,\
redundantLetError,\
redundantNilInit,\
redundantObjc,\
redundantParens,\
redundantPattern,\
redundantRawValues,\
redundantReturn,\
redundantSelf,\
redundantType,\
redundantVoidReturnType,\
semicolons,\
sortedImports,\
sortedSwitchCases,\
spaceAroundBraces,\
spaceAroundBrackets,\
spaceAroundComments,\
spaceAroundGenerics,\
spaceAroundOperators,\
spaceAroundParens,\
spaceInsideBraces,\
spaceInsideBrackets,\
spaceInsideComments,\
spaceInsideGenerics,\
spaceInsideParens,\
strongOutlets,\
strongifiedSelf,\
todos,\
trailingCommas,\
trailingSpace,\
typeSugar,\
unusedArguments,\
void,\
wrap,\
wrapArguments,\
wrapAttributes,\
wrapEnumCases,\
wrapMultilineStatementBraces,\
wrapSwitchCases \
--disable braces,\
redundantInit,\
trailingClosures \
--commas inline \
--exponentcase uppercase \
--header strip \
--hexliteralcase uppercase \
--ifdef indent \
--indent 4 \
--self remove \
--semicolons never \
--swiftversion 5.2 \
--trimwhitespace always \
--maxwidth 130 \
--wraparguments before-first \
--funcattributes same-line \
--typeattributes same-line \
--varattributes same-line \
--wrapcollections before-first \
--exclude Pods \
--exclude Generated \
--exclude R.generated.swift \
--exclude fastlane/swift \
--exclude Dependencies \
--exclude LoopKit \
--exclude LibreTransmitter \
--exclude G7SensorKit \
--exclude dexcom-share-client-swift \
--exclude CGMBLEKit \
--exclude RileyLinkKit \
--exclude MinimedKit \
--exclude TidepoolService \
--exclude DanaKit \
--exclude MedtrumKit \
--exclude OmnipodKit \
--exclude LibreLoop \
--exclude RoundWhiteDiscKit \
--exclude AccuChekKit \
--exclude EversenseKit \
--exclude SyaiKit
      
