/*
 * In-process libFuzzer harness for ccextractor.
 *
 * WHY THIS EXISTS (harness conversion, justified):
 *   The historical Mayhem target ran the ccextractor CLI on a raw file input
 *   (`ccextractor @@`). On today's upstream tip that raw target is unfuzzable
 *   under ASan for two reasons:
 *     1. ccx_demuxer_open() -> (Rust) ccxr_demuxer_open() bumps
 *        parent->current_file as a side effect, so switch_to_next_file() reads
 *        inputfile[current_file+1], one past the (correctly sized) array. With
 *        -fno-sanitize-recover that heap-buffer-overflow READ aborts on EVERY
 *        input at startup, before any input byte is parsed.
 *     2. The mid-port Rust demuxer aborts (panic == abort) via .expect()/unwrap
 *        on trivial/malformed input, so it cannot be fuzzed productively.
 *
 *   This harness drives the SAME parsing code paths in-process (demuxer stream
 *   detection + the per-format demux/decode loops used by start_ccx()). It is
 *   built against ccextractor's mature pure-C pipeline via -DDISABLE_RUST (an
 *   upstream-supported build mode, `./build -min-rust`), which is the robust
 *   implementation the target was historically fuzzed against. The fuzz input
 *   is materialized to a temp file because several demuxers (MP4/MKV) reopen
 *   the input by name.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lib_ccx.h"
#include "ccx_common_option.h"
#include "ccx_common_constants.h"
#include "ccx_demuxer.h"
#include "ccx_mp4.h"

/* Globals normally defined in ccextractor.c, which we exclude from the fuzzer
 * build because it defines main(). */
volatile int terminate_asap = 0;
struct ccx_s_options ccx_options;
struct lib_ccx_ctx *signal_ctx;

/* Referenced by fatal() in utility.c; the real one prints a credits banner. */
void print_end_msg(void) {}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	char tmpl[] = "/tmp/ccxfuzz_XXXXXX";
	int fd = mkstemp(tmpl);
	if (fd < 0)
		return 0;
	if (size > 0)
	{
		ssize_t off = 0;
		while (off < (ssize_t)size)
		{
			ssize_t w = write(fd, data + off, size - off);
			if (w <= 0)
				break;
			off += w;
		}
	}
	close(fd);

	/* Fresh options every iteration: the code base reads the GLOBAL
	 * ccx_options throughout, so we reset it rather than a local copy. */
	init_options(&ccx_options);
	ccx_options.messages_target = 0;   /* quiet */
	ccx_options.gui_mode_reports = 0;
	ccx_options.print_file_reports = 0;
	ccx_options.no_progress_bar = 1;
	ccx_options.input_source = CCX_DS_FILE;
	ccx_options.write_format = CCX_OF_NULL; /* don't emit output files */

	/* Single input file. dinit_libraries() frees ctx->inputfile (which aliases
	 * ccx_options.inputfile) via free_rust_c_string_array(), so the array and
	 * its entries must be heap-allocated, matching how the CLI supplies them. */
	char **files = (char **)malloc(sizeof(char *));
	if (files == NULL)
	{
		unlink(tmpl);
		return 0;
	}
	files[0] = strdup(tmpl);
	ccx_options.inputfile = files;
	ccx_options.num_input_files = 1;

	struct lib_ccx_ctx *ctx = init_libraries(&ccx_options);
	if (ctx == NULL)
	{
		unlink(tmpl);
		return 0;
	}

	int ret = ctx->demux_ctx->open(ctx->demux_ctx, tmpl);
	if (ret >= 0)
	{
		prepare_for_new_file(ctx);
		int mode = ctx->demux_ctx->get_stream_mode(ctx->demux_ctx);
		switch (mode)
		{
			case CCX_SM_MP4:
				close_input_file(ctx);
#ifdef ENABLE_FFMPEG_MP4
				ccxr_processmp4(ctx, tmpl);
#else
				processmp4(ctx, &ctx->mp4_cfg, tmpl);
#endif
				break;
			case CCX_SM_MKV:
				matroska_loop(ctx);
				break;
			case CCX_SM_MCPOODLESRAW:
			case CCX_SM_SCC:
				raw_loop(ctx);
				break;
			case CCX_SM_RCWT:
				rcwt_loop(ctx);
				break;
			case CCX_SM_MYTH:
				myth_loop(ctx);
				break;
			default:
				general_loop(ctx);
				break;
		}
		close_input_file(ctx);
	}

	dinit_libraries(&ctx);
	unlink(tmpl);
	return 0;
}
