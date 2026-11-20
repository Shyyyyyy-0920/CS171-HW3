include("E:/CS171/ShanghaiTech-CS171/HW/CS171-HW3/data/CPM.cmake")
CPMAddPackage("NAME;spdlog;GIT_REPOSITORY;https://github.com/gabime/spdlog.git;GIT_TAG;v1.11.0;OPTIONS;SPDLOG_FMT_EXTERNAL ON")
set(spdlog_FOUND TRUE)