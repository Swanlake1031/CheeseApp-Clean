-- ============================================
-- 008_rls_policies.sql
-- 行级安全策略（Row Level Security）
-- 
-- 📖 这是什么？
-- RLS（Row Level Security）是 PostgreSQL 的安全特性
-- 可以控制用户只能访问自己有权限的数据行
-- 
-- 🔧 为什么需要 RLS？
-- 没有 RLS 的话，任何登录用户都能查看和修改所有数据
-- 有了 RLS，可以实现：
-- - 用户只能删除自己的帖子
-- - 用户只能看到自己的收藏
-- - 用户只能读取自己参与的会话的消息
-- 
-- 📝 RLS 策略类型：
-- SELECT: 控制谁能读取数据
-- INSERT: 控制谁能插入数据
-- UPDATE: 控制谁能更新数据
-- DELETE: 控制谁能删除数据
-- ============================================


-- ============================================
-- 第一步：启用 RLS
-- ============================================
-- 
-- 🎯 ALTER TABLE ... ENABLE ROW LEVEL SECURITY
-- 启用后，如果没有策略，任何人都无法访问数据
-- 所以必须先定义策略

-- 用户表
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- 帖子相关表
ALTER TABLE posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE post_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE rent_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE secondhand_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE team_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE forum_posts ENABLE ROW LEVEL SECURITY;

-- 互动相关表
ALTER TABLE favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE view_history ENABLE ROW LEVEL SECURITY;

-- 组队和拼车参与表
ALTER TABLE team_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_participants ENABLE ROW LEVEL SECURITY;

-- 聊天相关表
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;


-- ============================================
-- Profiles 表策略
-- ============================================

-- 📝 任何人都可以读取公开的用户信息
CREATE POLICY "公开资料可以被所有人读取" ON profiles
  FOR SELECT
  USING (true);  -- USING 条件为 true 表示允许所有

-- 📝 用户只能更新自己的资料
-- auth.uid() 返回当前登录用户的 ID
CREATE POLICY "用户只能更新自己的资料" ON profiles
  FOR UPDATE
  USING (auth.uid() = id)  -- 只能选中自己的行
  WITH CHECK (auth.uid() = id);  -- 只能更新成自己的数据


-- ============================================
-- Posts 表策略
-- ============================================

-- 📝 活跃的帖子可以被所有人看到
CREATE POLICY "活跃帖子公开可见" ON posts
  FOR SELECT
  USING (status = 'active');

-- 📝 用户可以看到自己的所有帖子（包括已删除的）
CREATE POLICY "用户可以看到自己的所有帖子" ON posts
  FOR SELECT
  USING (auth.uid() = user_id);

-- 📝 登录用户可以创建帖子
CREATE POLICY "登录用户可以创建帖子" ON posts
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 📝 用户只能更新自己的帖子
CREATE POLICY "用户只能更新自己的帖子" ON posts
  FOR UPDATE
  USING (auth.uid() = user_id);

-- 📝 用户只能删除自己的帖子
CREATE POLICY "用户只能删除自己的帖子" ON posts
  FOR DELETE
  USING (auth.uid() = user_id);


-- ============================================
-- Post Images 表策略
-- ============================================

-- 📝 活跃帖子的图片公开可见
CREATE POLICY "帖子图片公开可见" ON post_images
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM posts 
      WHERE posts.id = post_images.post_id 
        AND (posts.status = 'active' OR posts.user_id = auth.uid())
    )
  );

-- 📝 用户可以为自己的帖子上传图片
CREATE POLICY "用户可以上传自己帖子的图片" ON post_images
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM posts 
      WHERE posts.id = post_images.post_id 
        AND posts.user_id = auth.uid()
    )
  );

-- 📝 用户可以删除自己帖子的图片
CREATE POLICY "用户可以删除自己帖子的图片" ON post_images
  FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM posts 
      WHERE posts.id = post_images.post_id 
        AND posts.user_id = auth.uid()
    )
  );


-- ============================================
-- 帖子详情表策略（rent/secondhand/ride/team/forum）
-- ============================================
-- 
-- 📝 这些表的策略和 posts 表类似
-- 因为它们通过外键关联到 posts 表

-- Rent Posts
CREATE POLICY "租房帖子公开可见" ON rent_posts
  FOR SELECT USING (true);

CREATE POLICY "用户可以创建租房帖子" ON rent_posts
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = rent_posts.id AND posts.user_id = auth.uid())
  );

CREATE POLICY "用户可以更新自己的租房帖子" ON rent_posts
  FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = rent_posts.id AND posts.user_id = auth.uid())
  );

-- Secondhand Posts
CREATE POLICY "二手帖子公开可见" ON secondhand_posts
  FOR SELECT USING (true);

CREATE POLICY "用户可以创建二手帖子" ON secondhand_posts
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = secondhand_posts.id AND posts.user_id = auth.uid())
  );

CREATE POLICY "用户可以更新自己的二手帖子" ON secondhand_posts
  FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = secondhand_posts.id AND posts.user_id = auth.uid())
  );

-- Ride Posts
CREATE POLICY "拼车帖子公开可见" ON ride_posts
  FOR SELECT USING (true);

CREATE POLICY "用户可以创建拼车帖子" ON ride_posts
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = ride_posts.id AND posts.user_id = auth.uid())
  );

CREATE POLICY "用户可以更新自己的拼车帖子" ON ride_posts
  FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = ride_posts.id AND posts.user_id = auth.uid())
  );

-- Team Posts
CREATE POLICY "组队帖子公开可见" ON team_posts
  FOR SELECT USING (true);

CREATE POLICY "用户可以创建组队帖子" ON team_posts
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = team_posts.id AND posts.user_id = auth.uid())
  );

CREATE POLICY "用户可以更新自己的组队帖子" ON team_posts
  FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = team_posts.id AND posts.user_id = auth.uid())
  );

-- Forum Posts
CREATE POLICY "论坛帖子公开可见" ON forum_posts
  FOR SELECT USING (true);

CREATE POLICY "用户可以创建论坛帖子" ON forum_posts
  FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = forum_posts.id AND posts.user_id = auth.uid())
  );

CREATE POLICY "用户可以更新自己的论坛帖子" ON forum_posts
  FOR UPDATE
  USING (
    EXISTS (SELECT 1 FROM posts WHERE posts.id = forum_posts.id AND posts.user_id = auth.uid())
  );


-- ============================================
-- Favorites 表策略
-- ============================================

-- 📝 用户只能看到自己的收藏
CREATE POLICY "用户只能查看自己的收藏" ON favorites
  FOR SELECT
  USING (auth.uid() = user_id);

-- 📝 登录用户可以添加收藏
CREATE POLICY "用户可以添加收藏" ON favorites
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 📝 用户只能删除自己的收藏
CREATE POLICY "用户可以删除自己的收藏" ON favorites
  FOR DELETE
  USING (auth.uid() = user_id);


-- ============================================
-- Comments 表策略
-- ============================================

-- 📝 评论公开可见
CREATE POLICY "评论公开可见" ON comments
  FOR SELECT
  USING (NOT is_deleted);

-- 📝 登录用户可以发表评论
CREATE POLICY "登录用户可以发表评论" ON comments
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 📝 用户只能编辑自己的评论
CREATE POLICY "用户可以编辑自己的评论" ON comments
  FOR UPDATE
  USING (auth.uid() = user_id);

-- 📝 用户只能删除自己的评论
CREATE POLICY "用户可以删除自己的评论" ON comments
  FOR DELETE
  USING (auth.uid() = user_id);


-- ============================================
-- Likes 表策略
-- ============================================

-- 📝 点赞记录公开可见（用于显示点赞数）
CREATE POLICY "点赞记录公开可见" ON likes
  FOR SELECT USING (true);

-- 📝 登录用户可以点赞
CREATE POLICY "用户可以点赞" ON likes
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 📝 用户可以取消自己的点赞
CREATE POLICY "用户可以取消点赞" ON likes
  FOR DELETE
  USING (auth.uid() = user_id);


-- ============================================
-- Conversations 表策略
-- ============================================

-- 📝 用户只能看到自己参与的会话
CREATE POLICY "用户只能查看自己的会话" ON conversations
  FOR SELECT
  USING (auth.uid() = user1_id OR auth.uid() = user2_id);

-- 📝 登录用户可以创建会话
CREATE POLICY "用户可以创建会话" ON conversations
  FOR INSERT
  WITH CHECK (auth.uid() = user1_id OR auth.uid() = user2_id);

-- 📝 参与者可以更新会话（如未读数）
CREATE POLICY "参与者可以更新会话" ON conversations
  FOR UPDATE
  USING (auth.uid() = user1_id OR auth.uid() = user2_id);


-- ============================================
-- Messages 表策略
-- ============================================

-- 📝 用户只能看到自己会话中的消息
CREATE POLICY "用户只能查看自己会话的消息" ON messages
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM conversations
      WHERE conversations.id = messages.conversation_id
        AND (conversations.user1_id = auth.uid() OR conversations.user2_id = auth.uid())
    )
  );

-- 📝 用户只能在自己的会话中发消息
CREATE POLICY "用户可以在自己的会话中发消息" ON messages
  FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id AND
    EXISTS (
      SELECT 1 FROM conversations
      WHERE conversations.id = messages.conversation_id
        AND (conversations.user1_id = auth.uid() OR conversations.user2_id = auth.uid())
    )
  );


-- ============================================
-- Team Members 和 Ride Participants 表策略
-- ============================================

-- Team Members
CREATE POLICY "团队成员信息可见" ON team_members
  FOR SELECT USING (true);

CREATE POLICY "用户可以申请加入团队" ON team_members
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 团队创建者可以更新成员状态
CREATE POLICY "团队创建者可以管理成员" ON team_members
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM posts
      WHERE posts.id = team_members.team_id
        AND posts.user_id = auth.uid()
    )
  );

-- Ride Participants
CREATE POLICY "拼车参与者信息可见" ON ride_participants
  FOR SELECT USING (true);

CREATE POLICY "用户可以参与拼车" ON ride_participants
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "司机可以管理参与者" ON ride_participants
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM posts
      WHERE posts.id = ride_participants.ride_id
        AND posts.user_id = auth.uid()
    )
  );


-- ============================================
-- View History 表策略
-- ============================================

CREATE POLICY "用户只能查看自己的浏览历史" ON view_history
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "用户可以记录浏览历史" ON view_history
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);


-- ============================================
-- 🎉 完成！
-- ============================================
-- 
-- 现在数据库有了完整的安全策略：
-- ✅ 用户只能修改自己的数据
-- ✅ 敏感信息（收藏、聊天）只有本人可见
-- ✅ 公开信息（帖子、评论）所有人可见
-- ✅ 防止未授权的数据访问
