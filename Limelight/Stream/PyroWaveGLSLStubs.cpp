#include <string>
#include <vector>

namespace Granite {

enum class Stage { Vertex, Fragment, Compute };

class FilesystemInterface;

class GLSLCompiler {
public:
  GLSLCompiler(FilesystemInterface &) {}
  void set_source_from_file(const std::string &, Stage) {}
  void set_include_directories(const std::vector<std::string> *) {}
  uint64_t get_source_hash() const { return 0; }
  bool compile(std::string &,
               const std::vector<std::pair<std::string, int>> *) const {
    return false;
  }
};

} // namespace Granite
