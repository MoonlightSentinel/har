# Note: recommended way is via `dub build`
out_dir=./out/

DC=dmd

all: har run_tests

har: harmain.d src/archive/har.d
	${DC} -of=${out_dir}/har -g -debug harmain.d src/archive/har.d

run_tests:
	${DC} -cov src/archive/har.d -run test/hartests.d
	rdmd test_command_line_tool.d
