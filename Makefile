# ============================================================
# Lenovo Miix 720 Camera Improve — Makefile
# 编译 camera-router (前摄) 和 ov5670-router (后摄)
# ============================================================

CC      = gcc
CFLAGS  = -D_GNU_SOURCE -O2 -Wall $(shell pkg-config --cflags gstreamer-1.0 gstreamer-video-1.0)
LDLIBS  = $(shell pkg-config --libs gstreamer-1.0 gstreamer-video-1.0) -lpthread

# ---- targets ----
.PHONY: all clean front back run-front help

all: front back

front: front_camera/pipeline/camera-router
back: back_camera/scripts/ov5670-router

front_camera/pipeline/camera-router: front_camera/pipeline/camera-router.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

back_camera/scripts/ov5670-router: back_camera/scripts/ov5670-router.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f front_camera/pipeline/camera-router back_camera/scripts/ov5670-router

# ---- run (需要 video/render group 权限) ----
run-front: front
	./front_camera/pipeline/camera-router

run-back: back
	./back_camera/scripts/ov5670-router

run-python-front:
	python3 front_camera/pipeline/camera-router.py

help:
	@echo "Targets:"
	@echo "  all          - 编译前摄 + 后摄路由"
	@echo "  front        - 编译前摄 camera-router"
	@echo "  back         - 编译后摄 ov5670-router"
	@echo "  clean        - 删除编译产物"
	@echo "  run-front    - 运行前摄 C 路由 (需权限)"
	@echo "  run-back     - 运行后摄 C 路由 (需权限)"
	@echo "  run-python-front - 运行前摄 Python 路由"
