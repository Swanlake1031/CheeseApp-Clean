-- ============================================
-- 006_forum_posts.sql
-- 论坛/树洞模块数据库表
-- 
-- 📖 这是什么？
-- 这个文件创建论坛（树洞）相关的数据库表
-- 用于发布和浏览讨论帖子
-- 
-- 📝 使用场景：
-- - 匿名吐槽/倾诉
-- - 生活分享
-- - 求助提问
-- - 表白墙
-- - 校园新闻和公告
-- - 经验分享
-- ============================================


-- ============================================
-- 论坛详情表 (forum_posts)
-- ============================================

CREATE TABLE forum_posts (
  -- 主键，关联到 posts 表
  id UUID PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE,
  
  -- ============================================
  -- 分类信息
  -- ============================================
  
  -- category 帖子类别
  -- confession: 树洞/倾诉（通常匿名）
  -- question: 求助提问
  -- share: 经验分享
  -- news: 校园新闻
  -- life: 生活日常
  -- love: 表白墙
  -- rant: 吐槽
  -- other: 其他
  category TEXT NOT NULL CHECK (category IN (
    'confession', 'question', 'share', 'news',
    'life', 'love', 'rant', 'other'
  )),
  
  -- ============================================
  -- 标签系统
  -- ============================================
  
  -- tags 帖子标签
  -- 存储为 JSONB 数组，例如：["UCLA", "CS", "期末"]
  tags JSONB DEFAULT '[]'::JSONB,
  
  -- ============================================
  -- 互动限制
  -- ============================================
  
  -- allow_comments 是否允许评论
  allow_comments BOOLEAN DEFAULT TRUE,
  
  -- is_pinned 是否置顶
  is_pinned BOOLEAN DEFAULT FALSE,
  
  -- is_locked 是否锁定（锁定后不能评论）
  is_locked BOOLEAN DEFAULT FALSE,
  
  -- ============================================
  -- 互动统计（冗余存储，提高查询性能）
  -- ============================================
  
  -- like_count 点赞数
  like_count INTEGER DEFAULT 0 CHECK (like_count >= 0),
  
  -- comment_count 评论数
  comment_count INTEGER DEFAULT 0 CHECK (comment_count >= 0)
);


-- ============================================
-- 创建索引
-- ============================================

-- 类别索引
CREATE INDEX forum_posts_category_idx ON forum_posts (category);

-- 标签搜索索引
CREATE INDEX forum_posts_tags_idx ON forum_posts USING GIN (tags);

-- 置顶帖索引
CREATE INDEX forum_posts_pinned_idx ON forum_posts (is_pinned) WHERE is_pinned = TRUE;

-- 热门帖子索引（按点赞+评论排序）
CREATE INDEX forum_posts_hot_idx ON forum_posts (like_count DESC, comment_count DESC);


-- ============================================
-- 创建论坛帖子的便捷函数
-- ============================================

CREATE OR REPLACE FUNCTION create_forum_post(
  p_user_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_category TEXT,
  p_tags TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_allow_comments BOOLEAN DEFAULT TRUE,
  p_is_anonymous BOOLEAN DEFAULT FALSE  -- 树洞通常匿名
)
RETURNS UUID AS $$
DECLARE
  v_post_id UUID;
BEGIN
  -- 创建基础帖子
  INSERT INTO posts (user_id, type, title, description, is_anonymous)
  VALUES (p_user_id, 'forum', p_title, p_description, p_is_anonymous)
  RETURNING id INTO v_post_id;
  
  -- 创建论坛详情
  INSERT INTO forum_posts (id, category, tags, allow_comments)
  VALUES (v_post_id, p_category, to_jsonb(p_tags), p_allow_comments);
  
  RETURN v_post_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 创建论坛帖子视图
-- ============================================

CREATE OR REPLACE VIEW forum_posts_view AS
SELECT 
  f.*,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.view_count,
  p.created_at,
  p.updated_at,
  -- 如果是匿名帖子，不返回用户真实信息
  CASE WHEN p.is_anonymous THEN NULL ELSE pr.full_name END AS user_name,
  CASE WHEN p.is_anonymous THEN NULL ELSE pr.avatar_url END AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  -- 图片
  COALESCE(
    (SELECT json_agg(
      json_build_object('id', pi.id, 'url', pi.url, 'order_index', pi.order_index)
      ORDER BY pi.order_index
    ) FROM post_images pi WHERE pi.post_id = f.id),
    '[]'::json
  ) AS images
FROM forum_posts f
JOIN posts p ON f.id = p.id
JOIN profiles pr ON p.user_id = pr.id
WHERE p.status = 'active';


-- ============================================
-- 评论表
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 存储所有帖子的评论（不仅仅是论坛帖子）
-- 支持多层嵌套回复

CREATE TABLE comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- 所属帖子
  post_id UUID REFERENCES posts(id) ON DELETE CASCADE NOT NULL,
  
  -- 评论者
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- 父评论（用于实现回复功能）
  -- NULL 表示这是顶级评论
  -- 有值表示这是对某条评论的回复
  parent_id UUID REFERENCES comments(id) ON DELETE CASCADE,
  
  -- 评论内容
  content TEXT NOT NULL,
  
  -- 是否匿名
  is_anonymous BOOLEAN DEFAULT FALSE,
  
  -- 点赞数
  like_count INTEGER DEFAULT 0 CHECK (like_count >= 0),
  
  -- 是否被删除（软删除）
  is_deleted BOOLEAN DEFAULT FALSE,
  
  -- 时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 评论索引
CREATE INDEX comments_post_idx ON comments (post_id);
CREATE INDEX comments_user_idx ON comments (user_id);
CREATE INDEX comments_parent_idx ON comments (parent_id);
CREATE INDEX comments_created_idx ON comments (created_at DESC);

-- 评论的 updated_at 触发器
CREATE TRIGGER comments_updated_at
  BEFORE UPDATE ON comments
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at();


-- ============================================
-- 点赞表
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 记录用户对帖子和评论的点赞
-- 使用复合主键防止重复点赞

CREATE TABLE likes (
  -- 点赞者
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- 点赞目标类型
  -- post: 帖子
  -- comment: 评论
  target_type TEXT NOT NULL CHECK (target_type IN ('post', 'comment')),
  
  -- 目标 ID
  target_id UUID NOT NULL,
  
  -- 点赞时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- 复合主键：同一用户对同一目标只能点赞一次
  PRIMARY KEY (user_id, target_type, target_id)
);

-- 点赞索引
CREATE INDEX likes_target_idx ON likes (target_type, target_id);


-- ============================================
-- 更新点赞计数的触发器
-- ============================================

CREATE OR REPLACE FUNCTION update_like_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- 新增点赞
    IF NEW.target_type = 'post' THEN
      UPDATE forum_posts SET like_count = like_count + 1 WHERE id = NEW.target_id;
    ELSIF NEW.target_type = 'comment' THEN
      UPDATE comments SET like_count = like_count + 1 WHERE id = NEW.target_id;
    END IF;
  ELSIF TG_OP = 'DELETE' THEN
    -- 取消点赞
    IF OLD.target_type = 'post' THEN
      UPDATE forum_posts SET like_count = like_count - 1 WHERE id = OLD.target_id;
    ELSIF OLD.target_type = 'comment' THEN
      UPDATE comments SET like_count = like_count - 1 WHERE id = OLD.target_id;
    END IF;
  END IF;
  
  RETURN NULL;  -- 返回 NULL 因为这是 AFTER 触发器
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER likes_count_trigger
  AFTER INSERT OR DELETE ON likes
  FOR EACH ROW
  EXECUTE FUNCTION update_like_count();


-- ============================================
-- 更新评论计数的触发器
-- ============================================

CREATE OR REPLACE FUNCTION update_comment_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE forum_posts SET comment_count = comment_count + 1 
    WHERE id = NEW.post_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE forum_posts SET comment_count = comment_count - 1 
    WHERE id = OLD.post_id;
  END IF;
  
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER comments_count_trigger
  AFTER INSERT OR DELETE ON comments
  FOR EACH ROW
  EXECUTE FUNCTION update_comment_count();


-- ============================================
-- 🎉 完成！
-- ============================================
